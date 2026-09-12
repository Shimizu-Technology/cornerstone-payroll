# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollReview::RevisionService do
  let!(:organization) { create(:organization, name: "Revision Review Firm") }
  let!(:company) { create(:company, organization: organization, client_payroll_approval_required: true) }
  let!(:staff) { create(:user, company: company, organization: organization, role: "manager", active: true) }
  let!(:client) { create(:user, company: company, organization: organization, role: "client", active: true) }
  let!(:other_client) { create(:user, company: create(:company), role: "client", active: true) }
  let!(:employee) { create(:employee, company: company) }
  let!(:pay_period) { create(:pay_period, company: company, status: "calculated", calculated_at: Time.current) }
  let!(:payroll_item) do
    create(:payroll_item, company: company, pay_period: pay_period, employee: employee,
                          hours_worked: 80, gross_pay: 1_600, total_deductions: 250, net_pay: 1_350)
  end

  before do
    CompanyAssignment.create!(user: client, company: company)
  end

  subject(:service) { described_class.new(pay_period: pay_period, actor: staff) }

  it "issues an immutable checksum revision and reuses it while payroll is unchanged" do
    first = service.issue!
    second = service.issue!

    expect(second).to eq(first)
    expect(first).to have_attributes(revision: 1, status: "pending", company_id: company.id)
    expect(first.calculation_checksum).to match(/\A[0-9a-f]{64}\z/)
    expect(first.calculation_snapshot.dig("payroll_items", 0, "employee_id")).to eq(employee.id)
    expect(first.calculation_snapshot.dig("payroll_items", 0, "employee")).to include(
      "id" => employee.id,
      "first_name" => employee.first_name,
      "last_name" => employee.last_name
    )
  end

  it "creates a new review revision when the displayed employee identity changes" do
    first = service.issue!
    employee.update!(last_name: "Corrected")

    second = service.issue!

    expect(second).to have_attributes(revision: 2, status: "pending")
    expect(second.calculation_checksum).not_to eq(first.calculation_checksum)
    expect(second.calculation_snapshot.dig("payroll_items", 0, "employee", "last_name")).to eq("Corrected")
  end

  it "supersedes an approved revision and creates a new pending revision when payroll changes" do
    first = service.issue!
    service.approve!(
      approver: client,
      recorded_by: client,
      method: "client_portal",
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
    )
    payroll_item.update!(hours_worked: 81, gross_pay: 1_620, net_pay: 1_370)

    second = service.issue!

    expect(first.reload).to have_attributes(status: "superseded", superseded_at: be_present)
    expect(first.approved_by).to eq(client)
    expect(second).to have_attributes(revision: 2, status: "pending")
    expect(second.calculation_checksum).not_to eq(first.calculation_checksum)
  end

  it "requires an exact approval statement from an assigned client user" do
    service.issue!

    expect do
      service.approve!(approver: client, recorded_by: client, method: "client_portal", acknowledgement: "Received, thank you!")
    end.to raise_error(described_class::Error, /exact payroll revision/)

    expect do
      service.approve!(approver: other_client, recorded_by: other_client, method: "client_portal",
                       acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT)
    end.to raise_error(described_class::Error, /assigned to this client/)
  end

  it "requires retained evidence when staff records an email attestation" do
    service.issue!

    expect do
      service.approve!(
        approver: client,
        recorded_by: staff,
        method: "email_attestation",
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      )
    end.to raise_error(described_class::Error, /message reference/)

    approved = service.approve!(
      approver: client,
      recorded_by: staff,
      method: "email_attestation",
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT,
      evidence_reference: "gmail-message-123"
    )
    expect(approved).to have_attributes(
      status: "approved",
      approved_by: client,
      approval_recorded_by: staff,
      approval_evidence_reference: "gmail-message-123"
    )
  end

  it "keeps saved revision identity and approval evidence immutable" do
    review_package = service.issue!
    service.approve!(
      approver: client,
      recorded_by: client,
      method: "client_portal",
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT,
      notes: "Approved as shown"
    )
    review_package.reload

    expect { review_package.update!(calculation_checksum: "f" * 64) }
      .to raise_error(ActiveRecord::RecordInvalid, /revision identity cannot be changed/)
    review_package.reload
    expect { review_package.update!(approval_notes: "Changed after approval") }
      .to raise_error(ActiveRecord::RecordInvalid, /approval evidence cannot be changed/)
    review_package.reload
    expect { review_package.update!(status: "pending", approved_at: nil, approved_by: nil) }
      .to raise_error(ActiveRecord::RecordInvalid, /cannot transition from approved/)
  end

  it "blocks payroll approval when approval is missing or the calculation changed" do
    review_package = service.issue!
    expect { service.verify_required_approval! }.to raise_error(described_class::Error, /still required/)

    service.approve!(
      approver: client,
      recorded_by: client,
      method: "client_portal",
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
    )
    expect(service.verify_required_approval!).to be(true)

    payroll_item.update!(net_pay: payroll_item.net_pay + 1)
    expect { service.verify_required_approval! }.to raise_error(described_class::Error, /changed after client review revision/)
    expect(review_package.reload).to be_approved
  end
end
