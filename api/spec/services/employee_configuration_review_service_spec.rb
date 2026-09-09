# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeConfigurationReviewService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company:, organization: company.organization, role: "accountant") }
  let(:employee) do
    create(
      :employee,
      company:,
      configuration_source: "quickbooks_history",
      configuration_review_status: "needs_review",
      configuration_review_items: [
        {
          "code" => "legacy_w4_allowances",
          "message" => "Confirm the employee's current W-4 election.",
          "fields" => %w[allowances w4_form_version]
        },
        {
          "code" => "time_off_setup_not_imported",
          "message" => "Review the time-off setup.",
          "fields" => []
        }
      ]
    )
  end

  before { create(:company_assignment, company:, user: actor) }

  it "resolves one item with a permanent reviewer snapshot and audit event" do
    expect do
      described_class.new(employee:, actor:).resolve!(
        code: "legacy_w4_allowances",
        resolution_note: "Confirmed the signed W-4 effective January 1, 2026.",
        acknowledgement: described_class::ACKNOWLEDGEMENT
      )
    end.to change(EmployeeConfigurationReviewResolution, :count).by(1)
      .and change(AuditLog.where(action: "employees#resolve_configuration_review"), :count).by(1)

    resolution = EmployeeConfigurationReviewResolution.last
    expect(resolution).to have_attributes(
      company:,
      employee:,
      item_code: "legacy_w4_allowances",
      reviewed_by_name: actor.name,
      reviewed_by_email: actor.email,
      reviewed_by_role: actor.role
    )
    expect(employee.reload.configuration_review_items.pluck("code")).to eq([ "time_off_setup_not_imported" ])
    expect(employee.configuration_review_status).to eq("needs_review")
    expect { resolution.update!(resolution_note: "Changed") }.to raise_error(ActiveRecord::RecordNotSaved)
  end

  it "marks the employee complete after the final open item is reviewed" do
    employee.update!(configuration_review_items: employee.configuration_review_items.last(1))

    described_class.new(employee:, actor:).resolve!(
      code: "time_off_setup_not_imported",
      resolution_note: "Employer confirmed that no time-off balance enters payroll.",
      acknowledgement: described_class::ACKNOWLEDGEMENT
    )

    expect(employee.reload.configuration_review_status).to eq("complete")
    expect(employee.configuration_review_items).to be_empty
  end

  it "requires missing source fields to be entered before resolution" do
    employee.update_columns(
      hire_date: nil,
      configuration_review_items: [
        { "code" => "verify_hire_date", "message" => "Confirm hire date", "fields" => %w[hire_date] }
      ]
    )

    expect do
      described_class.new(employee:, actor:).resolve!(
        code: "verify_hire_date",
        resolution_note: "Reviewed source record.",
        acknowledgement: described_class::ACKNOWLEDGEMENT
      )
    end.to raise_error(ArgumentError, /Hire date/)
  end
end
