# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestWorkspace::CloneJob do
  it "marks the workspace failed when its queued actor no longer exists" do
    organization = create(:organization)
    source = create(:company, organization: organization)
    workspace = create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox",
      migration_source_company: source,
      migration_rehearsal_status: "pending"
    )

    described_class.perform_now(workspace.id, -1)

    expect(workspace.reload).to have_attributes(
      migration_rehearsal_status: "failed",
      migration_rehearsal_error: TestWorkspace::Cloner::FAILURE_MESSAGE
    )
  end
end
