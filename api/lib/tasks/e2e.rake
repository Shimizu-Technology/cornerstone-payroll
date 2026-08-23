# frozen_string_literal: true

namespace :e2e do
  desc "Create the deterministic Gate 0 browser fixture in an empty test database"
  task seed: :environment do
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
