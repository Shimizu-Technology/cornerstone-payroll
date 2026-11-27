# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee lifecycle foundations model invariants" do
  let(:company) { create(:company, name: "Harborview Bistro") }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "org_admin") }

  describe "Employee partial save and no-blanking rules for readiness_gate_enforced" do
    it "allows saving a partial readiness_gate_enforced hire without SSN, DOB, hire_date, address, or w4_effective_on" do
      hire = Employee.new(
        company: company,
        first_name: "Jordan",
        last_name: "Sample",
        employment_type: "hourly",
        pay_rate: 0,
        pay_frequency: "biweekly",
        status: "active",
        readiness_gate_enforced: true,
        require_initial_w4_effective_on: true
      )

      expect(hire).to be_valid
      expect { hire.save! }.not_to raise_error
      expect(hire.readiness_gate_enforced).to be(true)
    end

    it "still enforces format validations whenever values are supplied on a readiness_gate_enforced hire" do
      bad_ssn = Employee.new(
        company: company,
        first_name: "Jordan",
        last_name: "Sample",
        employment_type: "hourly",
        pay_rate: 0,
        pay_frequency: "biweekly",
        ssn_encrypted: "12345",
        readiness_gate_enforced: true
      )
      expect(bad_ssn).not_to be_valid
      expect(bad_ssn.errors[:ssn]).to include("must contain exactly 9 digits")

      bad_ein = Employee.new(
        company: company,
        first_name: "Morgan",
        last_name: "Example",
        employment_type: "contractor",
        contractor_type: "business",
        contractor_pay_type: "flat_fee",
        pay_rate: 0,
        pay_frequency: "biweekly",
        contractor_ein: "12-34",
        readiness_gate_enforced: true
      )
      expect(bad_ein).not_to be_valid
      expect(bad_ein.errors[:contractor_ein]).to include("must contain exactly 9 digits")

      bad_hire_date = Employee.new(
        company: company,
        first_name: "Jordan",
        last_name: "Sample",
        employment_type: "hourly",
        pay_rate: 0,
        pay_frequency: "biweekly",
        hire_date: Date.new(1850, 1, 1),
        readiness_gate_enforced: true
      )
      expect(bad_hire_date).not_to be_valid
      expect(bad_hire_date.errors[:hire_date]).to include("must have a year between 1900 and next year")
    end

    it "forbids clearing already-completed filing fields (including DOB and w4_effective_on) on a readiness_gate_enforced employee" do
      hire = create(
        :employee,
        :hourly,
        company: company,
        date_of_birth: Date.new(1995, 6, 15),
        w4_effective_on: Date.new(2026, 11, 1),
        readiness_gate_enforced: true
      )

      expect(hire.update(ssn_encrypted: "")).to be(false)
      expect(hire.errors[:ssn]).to include("can't be blank")
      hire.reload

      expect(hire.update(date_of_birth: nil)).to be(false)
      expect(hire.errors[:date_of_birth]).to include("can't be blank")
      hire.reload

      expect(hire.update(w4_effective_on: nil)).to be(false)
      expect(hire.errors[:w4_effective_on]).to include("cannot clear a completed withholding effective date")
      hire.reload

      expect(hire.update(hire_date: nil)).to be(false)
      expect(hire.errors[:hire_date]).to include("can't be blank")
    end

    it "keeps existing required filing field validations unchanged when readiness_gate_enforced is false" do
      legacy = Employee.new(
        company: company,
        first_name: "Jordan",
        last_name: "Sample",
        employment_type: "hourly",
        pay_rate: 18.00,
        pay_frequency: "biweekly",
        readiness_gate_enforced: false,
        require_initial_w4_effective_on: true
      )

      expect(legacy).not_to be_valid
      expect(legacy.errors[:ssn]).to include("can't be blank")
      expect(legacy.errors[:hire_date]).to include("can't be blank")
      expect(legacy.errors[:w4_effective_on]).to include("is required unless incomplete employee entry is enabled")
    end
  end

  describe "EmployeeVerificationItem and PayPeriodVerificationAcknowledgement invariants" do
    it "prevents mutating or deleting acknowledgements and prevents superseding an acknowledged item" do
      employee = create(:employee, company: company)
      period = create(:pay_period, company: company)
      item = EmployeeVerificationItem.create!(
        company: company, employee: employee, event_kind: "compensation_change",
        status: "pending_verification", source_actor: actor
      )
      replacement = EmployeeVerificationItem.create!(
        company: company, employee: employee, event_kind: "compensation_change",
        status: "pending_verification", source_actor: actor
      )

      ack = PayPeriodVerificationAcknowledgement.create!(
        company: company, pay_period: period, employee_verification_item: item,
        employee: employee, acknowledged_by: actor, acknowledged_at: Time.current,
        item_status_snapshot: "pending_verification", item_updated_at_snapshot: item.updated_at
      )

      expect(ack.update(item_status_snapshot: "returned_to_client")).to be(false)
      expect(ack.destroy).to be(false)

      expect(item.update(status: "superseded", superseded_by: replacement)).to be(false)
      expect(item.errors[:status]).to include("cannot be superseded after being acknowledged in a committed pay run")
    end
  end
end
