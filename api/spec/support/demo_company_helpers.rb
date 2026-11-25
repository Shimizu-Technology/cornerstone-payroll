# frozen_string_literal: true

module DemoCompanyHelpers
  def create_demo_company(organization:, name: "Harbor Finch Kitchen", fixture_key: "harbor-finch-kitchen", **attributes)
    create(
      :company,
      organization: organization,
      name: name,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "demo",
      migration_rehearsal_status: "ready",
      test_workspace_manifest: { "version" => 1, "purpose" => "demo", "demo_fixture_key" => fixture_key },
      auto_create_fit_check: false,
      **attributes
    )
  end
end

RSpec.configure { |config| config.include DemoCompanyHelpers }
