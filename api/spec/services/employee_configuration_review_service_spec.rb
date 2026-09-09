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
    end.to raise_error(described_class::InvalidResolution, /Hire date/)
  end

  it "denies an actor without payroll operations access" do
    client = create(:user, company:, organization: company.organization, role: "client")

    expect do
      described_class.new(employee:, actor: client).resolve!(
        code: "legacy_w4_allowances",
        resolution_note: "Reviewed source record.",
        acknowledgement: described_class::ACKNOWLEDGEMENT
      )
    end.to raise_error(described_class::NotAuthorized, /payroll access/)
    expect(EmployeeConfigurationReviewResolution.count).to eq(0)
  end

  it "requires the exact acknowledgement and enforces the note limit" do
    service = described_class.new(employee:, actor:)

    expect do
      service.resolve!(code: "legacy_w4_allowances", resolution_note: "Reviewed.", acknowledgement: "REVIEWED")
    end.to raise_error(described_class::InvalidResolution, /Type MARK SETUP ITEM REVIEWED/)

    expect do
      service.resolve!(
        code: "legacy_w4_allowances",
        resolution_note: "a" * 1_001,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      )
    end.to raise_error(described_class::InvalidResolution, /too long/)
  end

  it "fails closed without dropping malformed retained review data" do
    valid_item = employee.configuration_review_items.first
    employee.update_columns(
      configuration_review_items: [ valid_item, { "code" => "malformed" } ],
      configuration_review_status: "needs_review"
    )

    expect do
      described_class.new(employee:, actor:).resolve!(
        code: valid_item.fetch("code"),
        resolution_note: "Reviewed source record.",
        acknowledgement: described_class::ACKNOWLEDGEMENT
      )
    end.to raise_error(described_class::InvalidResolution, /malformed/)
    expect(EmployeeConfigurationReviewResolution.count).to eq(0)

    expect(employee.reload.configuration_review_items).to include({ "code" => "malformed" })
    expect(employee.configuration_review_status).to eq("needs_review")
  end

  it "rejects mixed retained review items with invalid value types" do
    valid_item = employee.configuration_review_items.first
    malformed_items = [
      { "code" => 17, "message" => "Numeric code", "fields" => [] },
      { "code" => "numeric_message", "message" => 17, "fields" => [] },
      { "code" => "numeric_field", "message" => "Numeric field", "fields" => [ 17 ] }
    ]
    employee.update_columns(
      configuration_review_items: [ valid_item, *malformed_items ],
      configuration_review_status: "needs_review"
    )

    expect do
      described_class.new(employee:, actor:).resolve!(
        code: valid_item.fetch("code"),
        resolution_note: "Reviewed source record.",
        acknowledgement: described_class::ACKNOWLEDGEMENT
      )
    end.to raise_error(described_class::InvalidResolution, /malformed/)

    expect(EmployeeConfigurationReviewResolution.count).to eq(0)
    expect(employee.reload.configuration_review_items).to eq([ valid_item, *malformed_items ])
    expect(employee.configuration_review_status).to eq("needs_review")
  end

  it "never invokes an unapproved employee method from retained item fields" do
    employee.update_columns(
      configuration_review_items: [
        { "code" => "verify_hire_date", "message" => "Confirm hire date", "fields" => [ "destroy" ] }
      ]
    )

    expect do
      described_class.new(employee:, actor:).resolve!(
        code: "verify_hire_date",
        resolution_note: "Reviewed source record.",
        acknowledgement: described_class::ACKNOWLEDGEMENT
      )
    end.to raise_error(described_class::InvalidResolution, /unsupported employee fields/)

    expect(Employee.exists?(employee.id)).to be(true)
  end
end
