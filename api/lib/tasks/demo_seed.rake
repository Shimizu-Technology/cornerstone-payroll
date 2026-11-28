# frozen_string_literal: true

namespace :demo do
  # Not RlsTask.system: the seed enters its own scopes (system for the
  # organization, each company's own scope for its writes), which can't nest.
  desc "Seed the demo employers with fictional people and committed payroll (ORGANIZATION_ID, ACTOR_ID, optional LIFECYCLE_SHOWCASE=true). Safe to rerun."
  task seed: :environment do
    organization, actor = TenantScope.as_system(reason: "Find the demo seed organization and actor") do
      [ Organization.find(ENV.fetch("ORGANIZATION_ID")), User.find(ENV.fetch("ACTOR_ID")) ]
    end
    include_showcase = ENV["LIFECYCLE_SHOWCASE"] == "true"
    result = Current.set(user: actor) do
      DemoCompany::Seed.new(organization: organization, actor: actor, include_lifecycle_showcase: include_showcase).call
    end
    puts "OK    demo:seed companies=#{result.companies.map(&:id).join(',')} employees_created=#{result.employees_created} " \
         "periods_committed=#{result.periods_committed} periods_skipped=#{result.periods_skipped}"
  rescue DemoCompany::Seed::Refused, ActiveRecord::RecordInvalid, ArgumentError => e
    abort "FAIL  demo:seed #{e.message}"
  end

  desc "Seed the demo employers including the client-managed employee lifecycle showcase company (ORGANIZATION_ID, ACTOR_ID). Safe to rerun."
  task seed_lifecycle_showcase: :environment do
    organization, actor = TenantScope.as_system(reason: "Find the demo seed organization and actor") do
      [ Organization.find(ENV.fetch("ORGANIZATION_ID")), User.find(ENV.fetch("ACTOR_ID")) ]
    end
    result = Current.set(user: actor) do
      DemoCompany::Seed.new(organization: organization, actor: actor, include_lifecycle_showcase: true).call
    end
    puts "OK    demo:seed_lifecycle_showcase companies=#{result.companies.map(&:id).join(',')} employees_created=#{result.employees_created} " \
         "periods_committed=#{result.periods_committed} periods_skipped=#{result.periods_skipped}"
  rescue DemoCompany::Seed::Refused, ActiveRecord::RecordInvalid, ArgumentError => e
    abort "FAIL  demo:seed_lifecycle_showcase #{e.message}"
  end

  desc "Write the fictional QuickBooks export bundle and matching pay-stub PDFs to OUTPUT_DIR for the import and stub upload screens"
  task quickbooks_sample: :environment do
    result = DemoCompany::QuickbooksSample.new(output_dir: ENV.fetch("OUTPUT_DIR")).call
    puts "OK    demo:quickbooks_sample files=#{result.files.size} stub_pdfs=#{result.stub_pdfs.size}"
  end
end

namespace :demo do
  desc "Invite the demo employer's client manager and client user (ORGANIZATION_ID, ACTOR_ID, MANAGER_EMAIL, USER_EMAIL). Safe to rerun."
  task invite_clients: :environment do
    organization, actor = TenantScope.as_system(reason: "Find the demo invitation organization and actor") do
      [ Organization.find(ENV.fetch("ORGANIZATION_ID")), User.find(ENV.fetch("ACTOR_ID")) ]
    end
    outcomes = Current.set(user: actor) do
      DemoCompany::InviteClients.new(organization: organization, actor: actor,
        manager_email: ENV.fetch("MANAGER_EMAIL"), user_email: ENV.fetch("USER_EMAIL")).call
    end
    # Addresses are printed by domain only. Any undelivered invite fails the
    # task; a rerun retries it.
    outcomes.each do |outcome|
      puts "#{outcome.complete? ? 'OK  ' : 'FAIL'}  demo:invite_clients #{outcome.email.split('@').last} #{outcome.status}"
    end
    abort "FAIL  demo:invite_clients #{outcomes.count { |outcome| !outcome.complete? }} invite(s) not delivered; rerun to retry" unless outcomes.all?(&:complete?)
  rescue DemoCompany::InviteClients::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, KeyError => e
    abort "FAIL  demo:invite_clients #{e.message}"
  end
end

namespace :demo do
  desc "Give the demo employees their allow-listed email aliases in roster order (ORGANIZATION_ID, ACTOR_ID, EMAILS comma separated). Safe to rerun."
  task assign_employee_emails: :environment do
    organization, actor = TenantScope.as_system(reason: "Find the demo employee email organization and actor") do
      [ Organization.find(ENV.fetch("ORGANIZATION_ID")), User.find(ENV.fetch("ACTOR_ID")) ]
    end
    outcomes = Current.set(user: actor) do
      DemoCompany::AssignEmployeeEmails.new(organization: organization, actor: actor, emails: ENV.fetch("EMAILS")).call
    end
    # Addresses are printed by domain only.
    outcomes.each { |outcome| puts "OK    demo:assign_employee_emails #{outcome.name} #{outcome.email.split('@').last} #{outcome.status}" }
  rescue DemoCompany::AssignEmployeeEmails::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, KeyError => e
    abort "FAIL  demo:assign_employee_emails #{e.message}"
  end

  desc "Dry-run or apply simple demo names and invented addresses to existing demo companies (ORGANIZATION_ID, ACTOR_ID, optional COMPANY_IDS, EMPLOYEE_MAP, CLIENT_USER_MAP, APPLY=true). Safe to rerun."
  task rename_fixture: :environment do
    parse_id_map = lambda do |raw, env_name|
      text = raw.to_s.strip
      next {} if text.empty?

      if text.start_with?("{")
        parsed = JSON.parse(text)
        raise ArgumentError, "#{env_name} must be a JSON object" unless parsed.is_a?(Hash)

        parsed.each_with_object({}) do |(id, value), mapping|
          mapping[Integer(id.to_s.strip)] = value.to_s.strip
        end
      else
        text.split(",").each_with_object({}) do |pair, mapping|
          id, value = pair.split("=", 2)
          raise ArgumentError, "#{env_name} entries must be id=value" if id.blank? || value.blank?

          mapping[Integer(id.strip)] = value.strip
        end
      end
    end

    organization, actor = TenantScope.as_system(reason: "Find the demo rename organization and actor") do
      [ Organization.find(ENV.fetch("ORGANIZATION_ID")), User.find(ENV.fetch("ACTOR_ID")) ]
    end
    dry_run = ENV["APPLY"] != "true"
    employee_map = parse_id_map.call(ENV["EMPLOYEE_MAP"], "EMPLOYEE_MAP")
    client_user_map = parse_id_map.call(ENV["CLIENT_USER_MAP"], "CLIENT_USER_MAP")
    result = Current.set(user: actor) do
      DemoCompany::RenameFixture.new(
        organization: organization,
        actor: actor,
        dry_run: dry_run,
        company_ids: ENV["COMPANY_IDS"],
        employee_map: employee_map,
        client_user_map: client_user_map
      ).call
    end
    if result.dry_run
      result.changes.each do |change|
        fields = change.changes.keys.map(&:to_s).sort.join(",")
        puts "PLAN  #{change.record_type} id=#{change.record_id} fields=#{fields}"
      end
    end
    summary = result.counts.map { |type, count| "#{type}=#{count}" }.join(" ")
    summary = "none" if summary.blank?
    puts "OK    demo:rename_fixture mode=#{result.dry_run ? 'dry_run' : 'applied'} " \
         "companies=#{result.companies.map(&:id).join(',')} changes=#{result.changes.size} " \
         "unmatched_employees=#{result.unmatched_employee_ids.size} #{summary}"
  rescue DemoCompany::RenameFixture::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, KeyError, ArgumentError, JSON::ParserError => e
    abort "FAIL  demo:rename_fixture #{e.message}"
  end
end
