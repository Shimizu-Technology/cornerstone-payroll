# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriodCorrectionEvent, type: :model do
  let(:company) { create(:company) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:user) do
    User.create!(company: company, email: "actor@example.com", name: "Actor User", role: "admin", active: true)
  end

  describe "validations" do
    it "is valid with required attributes" do
      event = build(:pay_period_correction_event,
                    pay_period: pay_period,
                    company: company,
                    actor: user)
      expect(event).to be_valid
    end

    it "requires action_type" do
      event = build(:pay_period_correction_event,
                    pay_period: pay_period,
                    company: company,
                    action_type: nil)
      expect(event).not_to be_valid
      expect(event.errors[:action_type]).to be_present
    end

    it "rejects unknown action_type values" do
      event = build(:pay_period_correction_event,
                    pay_period: pay_period,
                    company: company,
                    action_type: "bogus_action")
      expect(event).not_to be_valid
    end

    it "requires reason" do
      event = build(:pay_period_correction_event,
                    pay_period: pay_period,
                    company: company,
                    reason: nil)
      expect(event).not_to be_valid
      expect(event.errors[:reason]).to be_present
    end

    it "requires company_id" do
      event = build(:pay_period_correction_event,
                    pay_period: pay_period,
                    company_id: nil)
      expect(event).not_to be_valid
    end
  end

  describe ".record!" do
    let(:department) { create(:department, company: company) }
    let(:employee) { create(:employee, company: company, department: department) }

    before do
      create(:payroll_item,
             pay_period: pay_period,
             employee: employee,
             gross_pay: 2000.00,
             net_pay: 1600.00,
             withholding_tax: 200.00,
             social_security_tax: 124.00,
             medicare_tax: 29.00,
             employer_social_security_tax: 124.00,
             employer_medicare_tax: 29.00)
    end

    it "creates an event with a financial snapshot" do
      event = PayPeriodCorrectionEvent.record!(
        action_type: "void_initiated",
        pay_period:  pay_period,
        actor:       user,
        reason:      "Duplicate submission"
      )

      expect(event).to be_persisted
      expect(event.action_type).to eq("void_initiated")
      expect(event.actor_id).to eq(user.id)
      expect(event.actor_name).to eq(user.name)
      expect(event.reason).to eq("Duplicate submission")
      expect(event.financial_snapshot["gross_pay"]).to eq(2000.0)
      expect(event.financial_snapshot["employee_count"]).to eq(1)
    end

    it "captures correct financial snapshot with multiple employees" do
      emp2 = create(:employee, company: company, department: department,
                    first_name: "Jane", last_name: "Smith", email: "jane@example.com")
      create(:payroll_item,
             pay_period: pay_period,
             employee: emp2,
             gross_pay: 3000.00,
             net_pay: 2400.00)

      event = PayPeriodCorrectionEvent.record!(
        action_type: "void_initiated",
        pay_period:  pay_period,
        actor:       user,
        reason:      "Test"
      )

      expect(event.financial_snapshot["gross_pay"]).to eq(5000.0)
      expect(event.financial_snapshot["employee_count"]).to eq(2)
    end
  end

  describe ".build_financial_snapshot" do
    let(:department) { create(:department, company: company) }
    let(:employee) { create(:employee, company: company, department: department) }

    it "returns a hash with all expected keys" do
      create(:payroll_item,
             pay_period: pay_period,
             employee: employee,
             gross_pay: 1500.00,
             net_pay: 1200.00,
             withholding_tax: 150.00,
             social_security_tax: 93.00,
             medicare_tax: 21.75,
             employer_social_security_tax: 93.00,
             employer_medicare_tax: 21.75)

      snapshot = PayPeriodCorrectionEvent.build_financial_snapshot(pay_period)

      expect(snapshot).to include(
        "gross_pay", "net_pay", "employee_count",
        "total_withholding", "total_social_security", "total_medicare",
        "total_employer_ss", "total_employer_medicare"
      )
    end
  end
end
