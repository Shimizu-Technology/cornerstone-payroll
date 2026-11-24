# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeClassificationTransitionService, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company) }
  let(:super_admin) { create(:user, company: company, role: "super_admin") }
  let(:contractor) do
    create(:employee, :contractor,
      company: company,
      first_name: "Asia",
      last_name: "Taylor",
      email: "asia@example.com",
      ssn_encrypted: "123-45-6789",
      hire_date: Date.new(2024, 1, 1),
      address_line1: "123 Marine Corps Dr",
      city: "Hagatna",
      state: "GU",
      zip: "96910")
  end
  let(:attributes) do
    {
      employment_type: "hourly",
      effective_date: Date.current.iso8601,
      reason: "Worker begins W-2 employment",
      pay_rate: 9.25,
      pay_frequency: "semimonthly",
      filing_status: "single",
      ssn: "123-45-6789",
      ssn_confirmation: "123-45-6789"
    }
  end

  it "creates a linked W-2 record and terminates the contractor record without moving history" do
    old_period = create(:pay_period, :committed,
      company: company,
      pay_date: 1.month.ago.to_date,
      end_date: 1.month.ago.to_date - 2.days,
      start_date: 1.month.ago.to_date - 15.days)
    historical_item = create(:payroll_item,
      employee: contractor,
      company: company,
      pay_period: old_period,
      employment_type: "contractor",
      gross_pay: 175,
      net_pay: 175)

    result = described_class.new(employee: contractor, attributes: attributes, actor: super_admin).call

    expect(result.previous_employee).to have_attributes(
      status: "terminated",
      termination_date: Date.current - 1.day
    )
    expect(result.new_employee).to have_attributes(
      previous_employee_id: contractor.id,
      employment_type: "hourly",
      pay_rate: 9.25.to_d,
      pay_frequency: "semimonthly",
      status: "active",
      hire_date: Date.current
    )
    expect(result.new_employee.ssn_encrypted).to eq("123-45-6789")
    expect(result.new_employee.primary_wage_rate.rate).to eq(9.25.to_d)
    expect(result.new_employee.employee_w4_elections.sole).to have_attributes(
      effective_on: Date.current,
      source: "employee_creation",
      created_by_id: super_admin.id
    )
    expect(result.new_employee).to be_document_readiness_required
    expect(result.new_employee.employee_document_requirements.pluck(:requirement_type)).to contain_exactly(
      "identity_and_work_authorization",
      "withholding_election"
    )
    expect(historical_item.reload.employee_id).to eq(contractor.id)
    expect(AuditLog.last).to have_attributes(
      action: "employees#transition_tax_classification",
      record_id: result.new_employee.id
    )
    expect(AuditLog.last.metadata).to include(
      "previous_employee_id" => contractor.id,
      "historical_payroll_preserved" => true
    )
    expect(contractor.employee_status_events).to be_empty
  end

  it "requires a super admin" do
    admin = create(:user, company: company, role: "admin")

    expect {
      described_class.new(employee: contractor, attributes: attributes, actor: admin).call
    }.to raise_error(described_class::Error, "Only a super admin can transition W-2/1099 classification")
  end

  it "accepts today's Guam date while UTC is still on the previous day" do
    travel_to Time.utc(2026, 11, 16, 22, 31) do # 8:31 a.m. Nov 17 in Guam
      attributes[:effective_date] = "2026-11-18"
      expect {
        described_class.new(employee: contractor, attributes: attributes, actor: super_admin).call
      }.to raise_error(described_class::Error, /cannot be in the future/)

      attributes[:effective_date] = "2026-11-17"
      expect(described_class.new(employee: contractor.reload, attributes: attributes, actor: super_admin).call).to be_present
    end
  end

  it "requires the W-2 SSN to be entered twice and match" do
    attributes[:ssn_confirmation] = "987-65-4321"

    expect {
      described_class.new(employee: contractor, attributes: attributes, actor: super_admin).call
    }.to raise_error(ActiveRecord::RecordInvalid, /does not match Social Security Number/)

    expect(contractor.reload).to be_active
    expect(contractor.next_employee).to be_nil
  end

  it "blocks a transition when payroll exists on or after the effective date" do
    period = create(:pay_period,
      company: company,
      pay_date: Date.current,
      end_date: Date.current - 2.days,
      start_date: Date.current - 15.days)
    create(:payroll_item,
      employee: contractor,
      company: company,
      pay_period: period,
      employment_type: "contractor")

    expect {
      described_class.new(employee: contractor, attributes: attributes, actor: super_admin).call
    }.to raise_error(described_class::Error, /payroll period.*still use this record/)

    expect(contractor.reload).to be_active
    expect(contractor.next_employee).to be_nil
  end

  it "runs shared contact validation, normalizes phone, and never copies email_verified_at or phone_confirmed_by_employee_at" do
    contractor.update_columns(
      email: "asia@example.com",
      phone: "555-0133",
      email_verified_at: 3.days.ago,
      phone_confirmed_by_employee_at: 3.days.ago,
      contact_source: "employee"
    )

    result = described_class.new(employee: contractor, attributes: attributes, actor: super_admin).call

    expect(result.new_employee).to have_attributes(
      email: "asia@example.com",
      phone: "+16715550133",
      email_verified_at: nil,
      phone_confirmed_by_employee_at: nil
    )
  end

  it "blocks transition when copied email is an explicitly marked placeholder unless staff supplies a valid replacement, while warning on unmarked structural patterns" do
    contractor.update_columns(email: "noemail@example.com")

    # Unmarked structural pattern warns without blocking.
    unmarked_result = EmployeeContactValidator.call(employee: contractor, company: company, email: "noemail@example.com")
    expect(unmarked_result).to be_valid
    expect(unmarked_result.warnings.map { |w| w[:code] }).to include("placeholder_email_pattern")

    # Explicitly marked placeholder blocks transition until replaced.
    EmployeePlaceholderEmail.create!(organization: company.organization, email: "noemail@example.com")
    expect {
      described_class.new(employee: contractor, attributes: attributes, actor: super_admin).call
    }.to raise_error(EmployeeContactValidator::ValidationError)

    result = described_class.new(
      employee: contractor,
      attributes: attributes.merge(email: "asia.real@example.com", phone: "555-0144"),
      actor: super_admin
    ).call
    expect(result.new_employee).to have_attributes(
      email: "asia.real@example.com",
      phone: "+16715550144",
      contact_source: "staff",
      email_verified_at: nil
    )
  end
end
