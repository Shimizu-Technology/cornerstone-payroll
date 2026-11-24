# frozen_string_literal: true

require_relative "../rls_task"

namespace :demo do
  desc "Create an empty permanent demo company (ORGANIZATION_ID, ACTOR_ID, FIXTURE_KEY, NAME, optional PAY_FREQUENCY)"
  RlsTask.system create_company: :environment do
    organization = Organization.find(ENV.fetch("ORGANIZATION_ID"))
    actor = User.find(ENV.fetch("ACTOR_ID"))
    company = Current.set(user: actor) do
      DemoCompany::Create.new(
        organization: organization,
        actor: actor,
        name: ENV.fetch("NAME"),
        fixture_key: ENV.fetch("FIXTURE_KEY"),
        pay_frequency: ENV.fetch("PAY_FREQUENCY", "biweekly")
      ).call
    end
    puts "OK    demo:create_company id=#{company.id} fixture_key=#{company.test_workspace_manifest['demo_fixture_key']}"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort "FAIL  demo:create_company #{e.message}"
  end
end
