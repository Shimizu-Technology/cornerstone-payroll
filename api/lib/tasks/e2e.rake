# frozen_string_literal: true

require_relative "../rls_task"

namespace :e2e do
  desc "Create the deterministic Gate 0 browser fixture in an empty test database"
  RlsTask.system seed: :environment do |task|
    Current.with_isolated_actor(AuditActor.system_job(task.name)) do
      require Rails.root.join("lib/e2e_release_fixture")

      output_path = ENV.fetch(
        "E2E_FIXTURE_PATH",
        Rails.root.join("../web/.e2e-fixtures/release.json").to_s
      )
      fixture = E2eReleaseFixture.seed!(output_path: output_path)

      puts "Gate 0 E2E fixture written to #{output_path}"
      puts "Workflow pay period: #{fixture.fetch(:workflow_pay_period_id)}"
    end
  end
end
