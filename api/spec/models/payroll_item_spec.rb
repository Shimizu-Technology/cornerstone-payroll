require "rails_helper"

RSpec.describe PayrollItem, type: :model do
  describe "check date" do
    let(:pay_period) do
      create(:pay_period, start_date: Date.new(2026, 12, 14), end_date: Date.new(2026, 12, 27), pay_date: Date.new(2026, 12, 31))
    end
    let(:item) { create(:payroll_item, pay_period: pay_period, employee: create(:employee, company: pay_period.company)) }

    it "may differ from the pay date within its tax year" do
      expect(item.update(check_date: Date.new(2026, 12, 30))).to be(true)
    end

    it "is rejected in another year, since W-2GU and year-to-date totals count the check in its pay date's year" do
      expect(item.update(check_date: Date.new(2027, 1, 2))).to be(false)
      expect(item.errors.full_messages).to include(
        "Check date must be in 2026, the year of this payroll's pay date (Dec 31, 2026). " \
        "W-2GU and year-to-date totals count this check in that year; change the payroll's pay date instead."
      )
    end
  end

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

  describe "#earnings_in_entry_order" do
    it "lists saved earnings by id whatever order the database returns, then unsaved ones in build order" do
      tips = PayrollItemEarning.new(id: 12, category: "tips", label: "Tips", amount: 80)
      regular = PayrollItemEarning.new(id: 11, category: "regular", label: "Regular Pay", amount: 1_149.60)
      bonus = PayrollItemEarning.new(category: "other", label: "Bonus", amount: 20)
      pto = PayrollItemEarning.new(category: "pto", label: "PTO", amount: 40)
      item = PayrollItem.new
      allow(item).to receive(:payroll_item_earnings).and_return([ bonus, tips, pto, regular ])

      expect(item.earnings_in_entry_order.map(&:label)).to eq([ "Regular Pay", "Tips", "Bonus", "PTO" ])
    end
  end
end
