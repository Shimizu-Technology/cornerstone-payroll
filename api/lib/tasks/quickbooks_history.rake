# frozen_string_literal: true

namespace :quickbooks_history do
  desc "Preview (and optionally apply/lock) a QuickBooks payroll-history bundle"
  task import: :environment do
    bundle_dir = Pathname.new(ENV.fetch("BUNDLE_DIR")).expand_path
    company_id = Integer(ENV.fetch("COMPANY_ID"), 10)
    apply_import = ENV["APPLY"] == "1"
    lock_import = ENV["LOCK"] == "1"

    raise ArgumentError, "BUNDLE_DIR must be an existing directory" unless bundle_dir.directory?
    raise ArgumentError, "LOCK=1 requires APPLY=1" if lock_import && !apply_import

    company = Company.find(company_id)
    actor = User.find_by!(email: ENV.fetch("ACTOR_EMAIL").downcase)
    authorized_actor = actor.can_access_company?(company.id) && StaffRolePolicy.allowed?(actor, :manage_client_configuration)
    raise ArgumentError, "ACTOR_EMAIL must identify a manager or administrator with access to COMPANY_ID" unless authorized_actor

    paths = bundle_dir.glob("**/*", File::FNM_DOTMATCH)
                      .reject(&:symlink?)
                      .select(&:file?)
                      .select { |path| QuickbooksHistory::BundleParser::ALLOWED_EXTENSIONS.include?(path.extname.downcase) }
                      .sort_by { |path| path.basename.to_s.downcase }
    raise ArgumentError, "No supported QuickBooks export files were found in BUNDLE_DIR" if paths.empty?

    files = paths.map do |path|
      QuickbooksHistory::BundleParser::SourceFile.new(
        original_filename: path.basename.to_s,
        path: path.to_s,
        size: path.size
      )
    end

    result = QuickbooksHistory::ImportService.new(company: company, files: files, actor: actor).call
    batch = result.batch

    if apply_import
      batch = QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).apply!(
        acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
      )
    end
    batch = QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).lock! if lock_import

    summary = batch.preview_summary.to_h
    reconciliation = batch.reconciliation_summary.to_h
    puts "QuickBooks historical import #{result.idempotent ? 'reused' : 'created'}"
    puts "Batch ID: #{batch.id}"
    puts "Company ID: #{company.id}"
    puts "Status: #{batch.status}"
    puts "Bundle digest: #{batch.bundle_digest.first(12)}..."
    puts "Files: #{summary.fetch('file_count', 0)}"
    puts "Workers: #{summary.fetch('worker_count', 0)}"
    puts "Periods: #{summary.fetch('period_count', 0)}"
    puts "Paychecks: #{summary.fetch('paycheck_count', 0)}"
    puts "Reconciliation: #{reconciliation['passed'] == true ? 'passed' : 'blocked'}"
    puts "Warnings: #{batch.warnings.size}"
    puts "Errors: #{batch.validation_errors.size}"
  end
end
