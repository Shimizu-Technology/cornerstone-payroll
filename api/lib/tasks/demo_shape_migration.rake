# frozen_string_literal: true

require "json"

namespace :demo do
  desc "Dry-run or convert old-shape demo companies to live + demo=true (ACTOR_ID, COMPANY_IDS, optional ORGANIZATION_ID, APPLY=true). Safe to rerun."
  task convert_to_flag: :environment do
    organization, actor = TenantScope.as_system(reason: "Resolve demo conversion actor and organization") do
      found_actor = User.find(ENV.fetch("ACTOR_ID"))
      found_org = ENV["ORGANIZATION_ID"].present? ? Organization.find(ENV["ORGANIZATION_ID"]) : found_actor.organization
      [ found_org, found_actor ]
    end

    dry_run = ENV["APPLY"] != "true"
    result = Current.set(user: actor) do
      DemoCompany::ConvertToFlag.new(
        organization: organization,
        actor: actor,
        company_ids: ENV["COMPANY_IDS"],
        dry_run: dry_run
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
  rescue DemoCompany::ConvertToFlag::Refused, ActiveRecord::RecordNotFound, KeyError, ArgumentError => e
    abort "FAIL  demo:convert_to_flag #{e.message}"
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

  desc "Diff before and after verification snapshots for demo shape migration (BEFORE, AFTER)"
  task verify_shape_diff: :environment do
    before_snapshot = JSON.parse(File.read(ENV.fetch("BEFORE")))
    after_snapshot = JSON.parse(File.read(ENV.fetch("AFTER")))
    diff = DemoCompany::VerifyShapeMigration.diff(before_snapshot, after_snapshot)

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
