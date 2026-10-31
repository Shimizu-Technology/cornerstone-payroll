# frozen_string_literal: true
# Run with bundle exec rails runner release_day.rb. See README.md.
# All persisted changes go through the application's supported rake tasks.
require 'json'
require 'uri'
require 'stringio'
require 'digest'
require 'rake'
$stdout.sync = true

module PayrollReleaseDay
  module_function

  def emit(event, **data)
    puts JSON.generate(event: event, at: Time.now.utc.iso8601, **data)
  end

  def timed(label, **data)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    emit('timing', step: label, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC)-start).round(3), **data)
    result
  end

  def inventory(company, year)
    PayrollFicaLegacyRecovery.new(company: company, year: year).inventory
  end

  def summary(inv)
    entries = inv.fetch(:employee_years)
    { company_id: inv[:company_id], tax_year: inv[:tax_year], employee_years: entries.size,
      employee_year_counts: inv[:employee_year_counts], row_counts: inv[:counts], plan_digest: inv[:plan_digest],
      held_reasons: entries.select { |e| e[:status]=='held' }.group_by { |e| e[:reason] || e[:rows].select { |r| r[:status]=='held' }.map { |r| r[:reason] }.uniq.join('; ') }.transform_values(&:size),
      history_review_open: entries.count { |e| e[:history_review_open] }, filing_review_open: entries.count { |e| e[:filing_review_open] } }
  end

  # Capture task output in memory: retained output is aggregate only.
  def task(name, variables, mode=nil)
    keys = %w[COMPANY_ID TAX_YEAR EMPLOYEE_ID EMPLOYEE_IDS ACTOR_ID REVIEW_REFERENCE PLAN_DIGEST APPLY DRY_RUN THROUGH_PAY_DATE EXTERNAL_SS_WAGE_BOUND EXTERNAL_MEDICARE_WAGE_BOUND]
    previous = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    variables.each { |key,value| ENV[key.to_s]=value.to_s }
    buffer = StringIO.new
    original = $stdout
    begin
      $stdout = buffer
      Rake::Task[name].reenable
      mode ? Rake::Task[name].invoke(mode) : Rake::Task[name].invoke
      name == 'payroll:legacy_check_voids' ? buffer.string : JSON.parse(buffer.string)
    ensure
      $stdout = original
      previous.each { |key,value| value.nil? ? ENV.delete(key) : ENV[key]=value }
    end
  end

  def run
    mode = ENV.fetch('RELEASE_MODE','preview')
    raise 'RELEASE_MODE must be preview or apply' unless %w[preview apply].include?(mode)
    raise 'Explicit RELEASE_APPLY=1 is required' if mode=='apply' && ENV['RELEASE_APPLY']!='1'
    raise 'RELEASE_APPLY is only valid with apply' if mode=='preview' && ENV['RELEASE_APPLY'].present?
    checks = { 'DEPLOYMENT_ENV'=>'EXPECTED_DEPLOYMENT_ENV', 'RENDER_SERVICE_ID'=>'EXPECTED_SERVICE_ID', 'RENDER_GIT_COMMIT'=>'EXPECTED_COMMIT' }
    checks.each { |actual,expected| raise "Wrong #{actual}" unless ENV.fetch(actual)==ENV.fetch(expected) }
    host = URI(ENV.fetch('DATABASE_URL')).host
    raise 'Wrong database host' unless host==ENV.fetch('EXPECTED_DB_HOST')
    Rails.logger.level = Logger::ERROR
    connection = ApplicationRecord.connection
    connection.execute("SET statement_timeout = '120s'")
    connection.execute("SET lock_timeout = '15s'")
    raise 'Migrations pending' if connection.pool.migration_context.needs_migration?
    year = Integer(ENV.fetch('TAX_YEAR'))
    through = Date.iso8601(ENV.fetch('THROUGH_PAY_DATE'))
    raise 'Through date must cover the tax year' unless through==Date.new(year,12,31)
    ids = ENV.fetch('COMPANY_IDS').split(',',-1).map { |v| Integer(v) }.uniq.sort
    raise 'No companies selected' if ids.empty?
    companies = ids.map { |id| Company.find(id) }
    companies.each do |co|
      raise "Excluded company #{co.id}" if co.name.match?(/Kasperbauer|Shimizu Technology|Migration Test|Clean Migration|\bTest Company\b/i) || co.respond_to?(:test_workspace?) && co.test_workspace?
    end
    actor = User.find(Integer(ENV.fetch('ACTOR_ID')))
    companies.each do |co|
      raise 'Unauthorized actor' unless actor.payroll_access_allowed? && actor.organization_admin? && actor.can_access_company?(co.id)
    end
    reference = ENV.fetch('REVIEW_REFERENCE')
    raise 'Review reference must be 10–1000 characters' unless reference.strip.length.between?(10,1000)
    raise 'Explicit confirmed zero outside wages required' unless ENV['CONFIRM_NO_OUTSIDE_WAGES']=='1'
    %w[EXTERNAL_SS_WAGE_BOUND EXTERNAL_MEDICARE_WAGE_BOUND].each { |k| raise "Explicit #{k}=0 required" unless ENV.fetch(k)=='0' }
    Rails.application.load_tasks unless Rake::Task.task_defined?('payroll:fica_legacy:recover')
    base = {TAX_YEAR:year,ACTOR_ID:actor.id,REVIEW_REFERENCE:reference,THROUGH_PAY_DATE:through.iso8601,EXTERNAL_SS_WAGE_BOUND:0,EXTERNAL_MEDICARE_WAGE_BOUND:0}
    emit('context',mode:mode,commit:ENV['RENDER_GIT_COMMIT'],service:ENV['RENDER_SERVICE_ID'],deployment:ENV['DEPLOYMENT_ENV'],actor_id:actor.id,actor_name:actor.name,company_ids:ids,tax_year:year)
    before = timed('before_inventory') do
      connection.transaction(isolation: :repeatable_read) do
        connection.execute('SET TRANSACTION READ ONLY')
        # Full 2026 company coverage, including excluded companies; no employee output.
        Company.order(:id).to_h { |co| [co.id, inventory(co,year).tap { |inv| emit('before_inventory',name:co.name,selected:ids.include?(co.id),**summary(inv)) }] }
      end
    end
    imported_employee_ids = ids.to_h do |id|
      # Preserve the original release scope: unresolved annual employee-years,
      # including those already conditionally calculable after a partial apply.
      selected = before.fetch(id).fetch(:employee_years).select { |entry| entry[:status] == 'held' || entry[:history_review_open] }
      [id, selected.map { |entry| entry.fetch(:employee_id) }.uniq.sort]
    end
    imported_plans = timed('imported_fica_inventory') do
      connection.transaction(isolation: :repeatable_read) do
        connection.execute('SET TRANSACTION READ ONLY')
        companies.to_h do |co|
          plan = ImportedPaycheckFicaReconciliation.new(company: co, year: year, employee_ids: imported_employee_ids.fetch(co.id)).inventory
          emit('imported_fica_plan', company_id: co.id, plan_digest: plan.fetch(:plan_digest), counts: plan.fetch(:counts),
            held_reasons: plan.fetch(:employee_years).select { |entry| entry[:status] == 'held' }.group_by { |entry| entry[:reason] }.transform_values(&:size))
          [co.id, plan]
        end
      end
    end
    script_sha = File.file?(__FILE__) ? Digest::SHA256.file(__FILE__).hexdigest : ENV.fetch('RUNNER_SCRIPT_SHA256')
    manifest = {script_sha256:script_sha,commit:ENV['RENDER_GIT_COMMIT'],service:ENV['RENDER_SERVICE_ID'],host:host,year:year,through:through.iso8601,company_ids:ids,actor_id:actor.id,reference:reference,external_bounds:[0,0],imported_plans:imported_plans.transform_values { |plan| plan.fetch(:plan_digest) },plans:ids.to_h { |id| [id,before.fetch(id)[:plan_digest]] }}
    preview_digest = FicaBasisEvidence.digest(manifest)
    emit('preview_manifest',digest:preview_digest,company_count:ids.size)
    if mode=='apply'
      raise 'Missing/mismatched PREVIEW_DIGEST; run and review a fresh preview' unless ENV['PREVIEW_DIGEST']==preview_digest
    end

    # Release order: finish ALL recovery batches before ANY source review.
    companies.each do |co|
      next unless before.fetch(co.id)[:counts].fetch(:recoverable)>0
      variables = base.merge(COMPANY_ID:co.id)
      plan = timed('recover_dry_run',company_id:co.id) { task('payroll:fica_legacy:recover',variables,'dry-run').fetch('company_years').fetch(0) }
      emit('recover_plan',company_id:co.id,plan_digest:plan.fetch('plan_digest'),recoverable_rows:plan.fetch('counts').fetch('recoverable'))
      if mode=='apply'
        receipt = timed('recover_apply',company_id:co.id) { task('payroll:fica_legacy:recover',variables.merge(PLAN_DIGEST:plan.fetch('plan_digest')),'apply').fetch('result') }
        emit('recover_receipt',company_id:co.id,applied_proofs:receipt.fetch('applied_proofs'),plan_digest:receipt.fetch('plan_digest'))
      end
    end
    companies.each do |co|
      inv = inventory(co,year)
      held_ids = inv.fetch(:employee_years).select { |e| e[:status]=='held' }.map { |e| e.fetch(:employee_id) }.uniq.sort
      # An imported-tax mismatch may stay held after source completeness was
      # already reviewed. Re-appending identical reviews would change every
      # imported plan on every apply, preventing a digest-locked second pass.
      latest_reviews = EmployeeYearFicaSourceReview.where(company: co, tax_year: year, employee_id: held_ids).order(:id).to_a.group_by(&:employee_id)
      held_ids.reject! do |id|
        review = latest_reviews[id]&.last
        review && review.through_pay_date >= through && review.external_ss_wage_bound.zero? && review.external_medicare_wage_bound.zero?
      end
      next if held_ids.empty?
      variables = base.merge(COMPANY_ID:co.id,EMPLOYEE_IDS:held_ids.join(','))
      preview = timed('review_sources_preview',company_id:co.id) { task('payroll:fica_legacy:review_sources',variables.merge(DRY_RUN:1)) }
      raise 'Wrong source review preview count' unless preview.fetch('reviews').size==held_ids.size
      emit('source_review_plan',company_id:co.id,employee_years:held_ids.size,employee_ids_sha256:Digest::SHA256.hexdigest(held_ids.join(',')),through:through.iso8601,external_ss_bound:0,external_medicare_bound:0)
      if mode=='apply'
        receipt = timed('review_sources_apply',company_id:co.id) { task('payroll:fica_legacy:review_sources',variables.merge(APPLY:1)) }
        raise 'Wrong applied review count' unless receipt.fetch('reviews').size==held_ids.size
        emit('source_review_receipt',company_id:co.id,applied_reviews:receipt.fetch('reviews').size)
      end
    end
    # Source review may change the proposed imported proof dependencies. Never
    # apply such a newly generated plan without a fresh operator preview.
    companies.each do |co|
      fresh = ImportedPaycheckFicaReconciliation.new(company: co, year: year, employee_ids: imported_employee_ids.fetch(co.id)).inventory
      if mode == 'apply' && fresh.fetch(:plan_digest) != imported_plans.fetch(co.id).fetch(:plan_digest)
        raise "Imported FICA plan changed after source/recovery steps for company #{co.id}; retain receipts and run a fresh preview"
      end
      next unless fresh.fetch(:counts).fetch('recoverable') > 0
      variables = base.merge(COMPANY_ID: co.id, EMPLOYEE_IDS: imported_employee_ids.fetch(co.id).join(','))
      plan = timed('reconcile_imports_dry_run', company_id: co.id) { task('payroll:fica_legacy:reconcile_imports', variables, 'dry-run').fetch('result') }
      raise 'Imported FICA preview changed' unless plan.fetch('plan_digest') == fresh.fetch(:plan_digest)
      emit('imported_fica_review', company_id: co.id, plan_digest: plan.fetch('plan_digest'), counts: plan.fetch('counts'))
      if mode == 'apply'
        receipt = timed('reconcile_imports_apply', company_id: co.id) { task('payroll:fica_legacy:reconcile_imports', variables.merge(PLAN_DIGEST: plan.fetch('plan_digest')), 'apply').fetch('result') }
        emit('imported_fica_receipt', company_id: co.id, applied_proofs: receipt.fetch('applied_proofs'), plan_digest: receipt.fetch('plan_digest'))
      end
    end
    timed('void_inventory') do
      csv = task('payroll:legacy_check_voids',{})
      require 'csv'
      rows = CSV.parse(csv,headers:true).map(&:to_h).select { |r| ids.include?(r.fetch('company_id').to_i) }
      emit('legacy_void_candidates',by_company:rows.group_by { |r| r.fetch('company_id') }.transform_values(&:size),
        candidates:rows.map { |r| r.slice('company_id','pay_period_id','payroll_item_id') },
        action:'Review against payment/YTD/liability evidence. This script never reverses or reissues paid wages.')
    end
    after = timed('after_inventory') do
      connection.transaction(isolation: :repeatable_read) do
        connection.execute('SET TRANSACTION READ ONLY')
        Company.order(:id).to_h { |co| [co.id,inventory(co,year).tap { |inv| emit('after_inventory',name:co.name,selected:ids.include?(co.id),**summary(inv)) }] }
      end
    end
    held = ids.to_h { |id| [id,after.fetch(id)[:employee_year_counts].fetch('held',0)] }.reject { |_,count| count.zero? }
    imported_held = companies.to_h do |co|
      plan = ImportedPaycheckFicaReconciliation.new(company: co, year: year, employee_ids: imported_employee_ids.fetch(co.id)).inventory
      [co.id, plan.fetch(:employee_years).count { |entry| entry[:status] == 'held' }]
    end.reject { |_, count| count.zero? }
    if held.any? || imported_held.any?
      emit('held_failure',mode:mode,held_by_company:held,imported_held_by_company:imported_held,preview_digest:preview_digest)
      return 3
    end
    emit('finished',mode:mode,selected_held_employee_years:0,preview_digest:preview_digest)
    0
  end
end

exit PayrollReleaseDay.run
