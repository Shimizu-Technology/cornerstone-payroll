# frozen_string_literal: true

require "json"

namespace :demo do
  def with_demo_migration_owner_connection(apply:)
    if !apply
      return yield
    end

    owner_url = ENV["MIGRATION_DATABASE_URL"].to_s.strip
    if owner_url.empty?
      if Rails.env.production?
        abort "FAIL  MIGRATION_DATABASE_URL (direct owner connection) is required when APPLY=true in production"
      end
      return yield
    end

    if RlsContextGuard.enabled?
      abort "FAIL  Boot with RLS_CONTEXT_GUARD_MODE=off when running APPLY=true on MIGRATION_DATABASE_URL"
    end

    direct_url = RlsConfiguration.direct_url!(owner_url, "MIGRATION_DATABASE_URL")
    previous_config = ActiveRecord::Base.connection_db_config
    ActiveRecord::Base.establish_connection(direct_url)
    yield
  ensure
    ActiveRecord::Base.establish_connection(previous_config) if previous_config
  end

  desc "Dry-run or convert old-shape demo companies to live + demo=true (ACTOR_ID, COMPANY_IDS, optional ORGANIZATION_ID, APPLY=true; requires MIGRATION_DATABASE_URL on APPLY=true in production). Safe to rerun."
  task convert_to_flag: :environment do
    apply = ENV["APPLY"] == "true"
    with_demo_migration_owner_connection(apply: apply) do
      organization, actor = TenantScope.as_system(reason: "Resolve demo conversion actor and organization") do
        found_actor = User.find(ENV.fetch("ACTOR_ID"))
        found_org = ENV["ORGANIZATION_ID"].present? ? Organization.find(ENV["ORGANIZATION_ID"]) : found_actor.organization
        [ found_org, found_actor ]
      end

      result = Current.set(user: actor) do
        DemoCompany::ConvertToFlag.new(
          organization: organization,
          actor: actor,
          company_ids: ENV["COMPANY_IDS"],
          dry_run: !apply
        ).call
      end

      if result.dry_run
        result.changes.each do |change|
          puts "PLAN  #{change.record_type} id=#{change.record_id} company_id=#{change.company_id} fields=#{change.fields.join(',')}"
        end
      end

      converted = result.converted_company_ids.any? ? result.converted_company_ids.join(",") : "none"
      already = result.already_converted_company_ids.any? ? result.already_converted_company_ids.join(",") : "none"
      puts "OK    demo:convert_to_flag mode=#{result.dry_run ? 'dry_run' : 'applied'} " \
           "converted=#{converted} already_converted=#{already} changes=#{result.changes.size}"
    end
  rescue DemoCompany::ConvertToFlag::Refused, ActiveRecord::RecordNotFound, KeyError, ArgumentError => e
    abort "FAIL  demo:convert_to_flag #{e.message}"
  end

  desc "Targeted per-company rollback from flag shape back to captured legacy shape (ACTOR_ID, COMPANY_IDS, BEFORE, optional ORGANIZATION_ID, APPLY=true; requires MIGRATION_DATABASE_URL on APPLY=true in production)"
  task revert_to_legacy_shape: :environment do
    apply = ENV["APPLY"] == "true"
    before_snapshot = JSON.parse(File.read(ENV.fetch("BEFORE")))
    with_demo_migration_owner_connection(apply: apply) do
      organization, actor = TenantScope.as_system(reason: "Resolve demo revert actor and organization") do
        found_actor = User.find(ENV.fetch("ACTOR_ID"))
        found_org = ENV["ORGANIZATION_ID"].present? ? Organization.find(ENV["ORGANIZATION_ID"]) : found_actor.organization
        [ found_org, found_actor ]
      end

      result = Current.set(user: actor) do
        DemoCompany::RevertToLegacyShape.new(
          organization: organization,
          actor: actor,
          company_ids: ENV["COMPANY_IDS"],
          before_snapshot: before_snapshot,
          dry_run: !apply
        ).call
      end

      reverted = result.reverted_company_ids.any? ? result.reverted_company_ids.join(",") : "none"
      already = result.already_legacy_company_ids.any? ? result.already_legacy_company_ids.join(",") : "none"
      puts "OK    demo:revert_to_legacy_shape mode=#{result.dry_run ? 'dry_run' : 'applied'} " \
           "reverted=#{reverted} already_legacy=#{already} links_reverted=#{result.links_reverted}"
    end
  rescue DemoCompany::RevertToLegacyShape::Refused, Errno::ENOENT, JSON::ParserError, ActiveRecord::RecordNotFound, KeyError, ArgumentError => e
    abort "FAIL  demo:revert_to_legacy_shape #{e.message}"
  end

  desc "Capture a read-only before/after verification snapshot for demo shape migration (ACTOR_ID, COMPANY_IDS, optional ORGANIZATION_ID, TAX_YEAR, CHECK_EMPLOYEE_SERVICE=true, OUTPUT)"
  task verify_shape_snapshot: :environment do
    organization, actor = TenantScope.as_system(reason: "Resolve demo verification actor and organization") do
      found_actor = User.find(ENV.fetch("ACTOR_ID"))
      found_org = ENV["ORGANIZATION_ID"].present? ? Organization.find(ENV["ORGANIZATION_ID"]) : found_actor.organization
      [ found_org, found_actor ]
    end

    tax_year = ENV["TAX_YEAR"].present? ? Integer(ENV["TAX_YEAR"], 10) : PayrollBusinessClock.today.year
    snapshot = DemoCompany::VerifyShapeMigration.capture(
      organization: organization,
      actor: actor,
      company_ids: ENV["COMPANY_IDS"],
      tax_year: tax_year,
      check_employee_service: ENV["CHECK_EMPLOYEE_SERVICE"] == "true"
    )
    json = JSON.pretty_generate(snapshot)
    if ENV["OUTPUT"].present?
      File.write(ENV["OUTPUT"], "#{json}\n")
      puts "OK    demo:verify_shape_snapshot companies=#{snapshot['companies'].keys.join(',')} output=#{ENV['OUTPUT']}"
    else
      puts json
    end
  rescue DemoCompany::VerifyShapeMigration::Error, ActiveRecord::RecordNotFound, KeyError, ArgumentError => e
    abort "FAIL  demo:verify_shape_snapshot #{e.message}"
  end

  desc "Diff before and after verification snapshots for demo shape migration (BEFORE, AFTER, COMPANY_IDS, optional ALLOW_ALREADY_CONVERTED=true)"
  task verify_shape_diff: :environment do
    before_snapshot = JSON.parse(File.read(ENV.fetch("BEFORE")))
    after_snapshot = JSON.parse(File.read(ENV.fetch("AFTER")))
    expected_ids = ENV.fetch("COMPANY_IDS")
    diff = DemoCompany::VerifyShapeMigration.diff(
      before_snapshot,
      after_snapshot,
      expected_company_ids: expected_ids,
      allow_already_converted: ENV["ALLOW_ALREADY_CONVERTED"] == "true"
    )

    diff.shape_changes.each do |company_id, changes|
      puts "SHAPE company_id=#{company_id} changed_fields=#{changes.size}"
    end

    if diff.passed?
      puts "OK    demo:verify_shape_diff companies=#{diff.company_ids.join(',')} unexpected_diffs=0"
    else
      diff.unexpected_diffs.each do |entry|
        puts "DIFF  #{entry[:path]} before=#{entry[:before].inspect} after=#{entry[:after].inspect}" \
             "#{entry.key?(:expected) ? " expected=#{entry[:expected].inspect}" : ''}"
      end
      abort "FAIL  demo:verify_shape_diff unexpected_diffs=#{diff.unexpected_diffs.size}"
    end
  rescue Errno::ENOENT, JSON::ParserError, KeyError => e
    abort "FAIL  demo:verify_shape_diff #{e.message}"
  end
end
