require "rails_helper"

RSpec.describe Employee, type: :model do
  describe "#active_wage_rates" do
    let!(:company) { create(:company) }
    let!(:department) { create(:department, company: company) }
    let!(:employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00
      )
    end

    let!(:inactive_rate) do
      EmployeeWageRate.create!(
        employee: employee,
        label: "Zulu",
        rate: 18.00,
        is_primary: false,
        active: false
      )
    end
    let!(:secondary_rate) do
      EmployeeWageRate.create!(
        employee: employee,
        label: "Bravo",
        rate: 22.00,
        is_primary: false,
        active: true
      )
    end
    let!(:primary_rate) do
      EmployeeWageRate.create!(
        employee: employee,
        label: "Alpha",
        rate: 25.00,
        is_primary: true,
        active: true
      )
    end

    it "uses the preloaded wage rate association without another query" do
      preloaded_employee = described_class.includes(:employee_wage_rates).find(employee.id)
      sql_queries = []

      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        sql_queries << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        preloaded_employee.active_wage_rates
      end

      employee_wage_rate_queries = sql_queries.select { |sql| sql.match?(/employee_wage_rates/i) }
      expect(employee_wage_rate_queries).to be_empty
    end

    it "returns active wage rates ordered by primary then label" do
      preloaded_employee = described_class.includes(:employee_wage_rates).find(employee.id)

      expect(preloaded_employee.active_wage_rates.map(&:id)).to eq([
        primary_rate.id,
        secondary_rate.id
      ])
      expect(preloaded_employee.active_wage_rates).not_to include(inactive_rate)
    end
  end

  describe "#primary_wage_rate" do
    let!(:company) { create(:company) }
    let!(:department) { create(:department, company: company) }
    let!(:employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00
      )
    end
    let!(:secondary_rate) do
      EmployeeWageRate.create!(
        employee: employee,
        label: "Bravo",
        rate: 22.00,
        is_primary: false,
        active: true
      )
    end
    let!(:primary_rate) do
      EmployeeWageRate.create!(
        employee: employee,
        label: "Alpha",
        rate: 25.00,
        is_primary: true,
        active: true
      )
    end

    it "returns the primary wage rate when wage rates are preloaded" do
      preloaded_employee = described_class.includes(:employee_wage_rates).find(employee.id)

      expect(preloaded_employee.primary_wage_rate).to eq(primary_rate)
    end
  end

  describe "pay rate normalization" do
    it "rounds pay_rate to cents before validation" do
      employee = build(:employee, pay_rate: 9.987654)

      employee.validate

      expect(employee.pay_rate.to_f).to eq(9.99)
    end

    it "rounds W-4 monetary fields to cents before validation" do
      employee = build(
        :employee,
        additional_withholding: 14.999,
        w4_dependent_credit: 1234.567,
        w4_step4a_other_income: 99.999,
        w4_step4b_deductions: 88.888
      )

      employee.validate

      expect(employee.additional_withholding.to_f).to eq(15.0)
      expect(employee.w4_dependent_credit.to_f).to eq(1234.57)
      expect(employee.w4_step4a_other_income.to_f).to eq(100.0)
      expect(employee.w4_step4b_deductions.to_f).to eq(88.89)
    end
  end

  describe "recurring payroll adjustments" do
    it "reads employee default adjustments for active adjustment helpers" do
      employee = build(
        :employee,
        default_payroll_adjustments: [
          { "label" => "Rent", "amount" => 150.0, "treatment" => "post_tax_deduction", "active" => true },
          { "label" => "Inactive", "amount" => 25.0, "treatment" => "post_tax_deduction", "active" => false }
        ]
      )

      expect(employee.active_payroll_adjustments.map { |adjustment| adjustment["label"] }).to eq([ "Rent" ])
      expect(employee.payroll_adjustments_total("post_tax_deduction")).to eq(150.0)
    end
  end

  describe "address validation" do
    it "allows W-2 employees to be saved without mailing address fields" do
      employee = build(:employee, address_line1: "", city: "", state: "", zip: "")

      expect(employee).to be_valid
    end

    it "does not require mailing address fields for contractors" do
      employee = build(:employee, :contractor, pay_rate: 50.0)

      expect(employee).to be_valid
    end

    it "does not emit a malformed city/state/zip line when address parts are blank" do
      employee = build(:employee, :contractor, address_line1: nil, address_line2: nil, city: nil, state: nil, zip: nil)

      expect(employee.full_address).to eq("")
    end
  end

  describe "YTD cache usage" do
    let!(:company) { create(:company) }
    let!(:employee) { create(:employee, company: company) }

    it "returns cached pre-period totals without hitting payroll_items again" do
      employee.cache_ytd_values!(
        year: 2026,
        as_of_pay_date: Date.new(2026, 2, 14),
        before_pay_period_id: 123,
        totals: {
          gross_pay: 1000.0,
          net_pay: 800.0,
          withholding_tax: 75.0,
          social_security_tax: 62.0,
          medicare_tax: 14.5,
          additional_withholding: 5.0,
          retirement: 10.0,
          roth_retirement: 6.0,
          insurance: 4.0,
          loans: 3.0
        }
      )

      expect(employee).not_to receive(:payroll_items)

      totals = employee.ytd_totals_before(
        year: 2026,
        pay_date: Date.new(2026, 2, 14),
        pay_period_id: 123
      )

      expect(totals).to include(
        gross_pay: 1000.0,
        net_pay: 800.0,
        withholding_tax: 75.0,
        social_security_tax: 62.0,
        medicare_tax: 14.5
      )
    end
  end
end
