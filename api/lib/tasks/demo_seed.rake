# frozen_string_literal: true

require_relative "../rls_task"

namespace :demo do
  desc "Seed the two demo employers with fictional people and committed payroll (ORGANIZATION_ID, ACTOR_ID). Safe to rerun."
  RlsTask.system seed: :environment do
    organization = Organization.find(ENV.fetch("ORGANIZATION_ID"))
    actor = User.find(ENV.fetch("ACTOR_ID"))
    result = Current.set(user: actor) { DemoCompany::Seed.new(organization: organization, actor: actor).call }
    puts "OK    demo:seed companies=#{result.companies.map(&:id).join(',')} employees_created=#{result.employees_created} " \
         "periods_committed=#{result.periods_committed} periods_skipped=#{result.periods_skipped}"
  rescue DemoCompany::Seed::Refused, ActiveRecord::RecordInvalid, ArgumentError => e
    abort "FAIL  demo:seed #{e.message}"
  end

  desc "Write the fictional QuickBooks export bundle and matching pay-stub PDF to OUTPUT_DIR for the import and stub upload screens"
  task quickbooks_sample: :environment do
    result = DemoCompany::QuickbooksSample.new(output_dir: ENV.fetch("OUTPUT_DIR")).call
    puts "OK    demo:quickbooks_sample files=#{result.files.size} stub_pdf=#{File.basename(result.stub_pdf)}"
  end
end
