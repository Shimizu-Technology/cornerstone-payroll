# frozen_string_literal: true

namespace :demo do
  # Not RlsTask.system: the seed enters its own scopes (system for the
  # organization, each company's own scope for its writes), which can't nest.
  desc "Seed the two demo employers with fictional people and committed payroll (ORGANIZATION_ID, ACTOR_ID). Safe to rerun."
  task seed: :environment do
    organization, actor = TenantScope.as_system(reason: "Find the demo seed organization and actor") do
      [ Organization.find(ENV.fetch("ORGANIZATION_ID")), User.find(ENV.fetch("ACTOR_ID")) ]
    end
    result = Current.set(user: actor) { DemoCompany::Seed.new(organization: organization, actor: actor).call }
    puts "OK    demo:seed companies=#{result.companies.map(&:id).join(',')} employees_created=#{result.employees_created} " \
         "periods_committed=#{result.periods_committed} periods_skipped=#{result.periods_skipped}"
  rescue DemoCompany::Seed::Refused, ActiveRecord::RecordInvalid, ArgumentError => e
    abort "FAIL  demo:seed #{e.message}"
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
end
