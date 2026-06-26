require "rails_helper"

RSpec.describe PayrollItem, type: :model do
  describe "pay precision normalization" do
    it "rounds pay_rate and stored wage rate entries to cents before validation" do
      payroll_item = build(
        :payroll_item,
        pay_period: create(:pay_period, :calculated),
        employee: create(:employee),
        pay_rate: 9.987654
      )

      payroll_item.wage_rate_hours = [
        {
          employee_wage_rate_id: 123,
          label: "Base",
          rate: 9.974,
          regular_hours: 40,
          overtime_hours: 2,
          is_primary: true,
          active: true
        }
      ]

      payroll_item.validate

      expect(payroll_item.pay_rate.to_f).to eq(9.99)
      expect(payroll_item.wage_rate_hours.first["rate"]).to eq(9.97)
    end

    it "keeps reported tips at least as high as tips paid out for regular payroll rows" do
      payroll_item = build(
        :payroll_item,
        reported_tips: 0,
        tips_paid_out: 42.25
      )

      payroll_item.validate

      expect(payroll_item.reported_tips).to eq(42.25)
    end

    it "allows negative paid-out tip deltas on corrective rows" do
      original = create(:payroll_item, tips_paid_out: 50.0)
      corrective = build(
        :payroll_item,
        pay_period: create(:pay_period, company: original.company, cycle: "supplemental", corrects_pay_period: original.pay_period),
        employee: original.employee,
        company: original.company,
        correction_for_payroll_item: original,
        tips_paid_out: -10.0
      )

      expect(corrective).to be_valid
    end
  end
end
