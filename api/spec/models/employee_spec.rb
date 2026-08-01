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

    it "supports legitimate high annual salaries" do
      employee = build(:employee, employment_type: "salary", pay_rate: 5_460_000)

      expect(employee).to be_valid
      expect(employee.pay_rate.to_f).to eq(5_460_000.0)
    end

    it "rejects a pay rate beyond the database precision" do
      employee = build(:employee, pay_rate: 1_000_000_000_000)

      expect(employee).not_to be_valid
      expect(employee.errors[:pay_rate]).to be_present
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

    it "copies employee defaults to a payroll item only until that item is explicitly overridden" do
      employee = create(
        :employee,
        default_payroll_adjustments: [
          { "label" => "Recurring Bonus", "amount" => 50.0, "treatment" => "taxable_addition", "active" => true }
        ]
      )
      pay_period = create(:pay_period, company: employee.company)
      item = build(:payroll_item, employee: employee, company: employee.company, pay_period: pay_period, payroll_adjustments: [])

      item.apply_default_payroll_adjustments_if_unset!(employee)
      expect(item.payroll_adjustments.first["label"]).to eq("Recurring Bonus")

      item.payroll_adjustments = []
      item.mark_payroll_adjustments_overridden!
      item.apply_default_payroll_adjustments_if_unset!(employee)
      expect(item.payroll_adjustments).to eq([])
    end
  end

  describe "address validation" do
    it "requires filing identity and address fields for new W-2 employees" do
      employee = build(:employee, address_line1: "", city: "", state: "", zip: "")

      expect(employee).not_to be_valid
      expect(employee.errors.attribute_names).to include(:address_line1, :city, :state, :zip)
    end

    it "does not require mailing address fields for contractors" do
      employee = build(:employee, :contractor, pay_rate: 50.0)

      expect(employee).to be_valid
    end

    it "requires filing fields when a contractor becomes a W-2 employee" do
      employee = create(:employee, :contractor, ssn_encrypted: nil, hire_date: nil)

      employee.employment_type = "hourly"

      expect(employee).not_to be_valid
      expect(employee.errors.attribute_names).to include(
        :hire_date, :ssn, :address_line1, :city, :state, :zip
      )
    end

    it "does not emit a malformed city/state/zip line when address parts are blank" do
      employee = build(:employee, :contractor, address_line1: nil, address_line2: nil, city: nil, state: nil, zip: nil)

      expect(employee.full_address).to eq("")
    end
  end

  describe "tax classification immutability" do
    it "allows hourly and salary changes within W-2 treatment" do
      employee = create(:employee, employment_type: "hourly")

      employee.assign_attributes(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)

      expect(employee).to be_valid
    end

    it "blocks changing between W-2 and 1099 on the same record" do
      employee = create(:employee, employment_type: "hourly")

      employee.employment_type = "contractor"

      expect(employee).not_to be_valid
      expect(employee.errors[:employment_type]).to include(
        "cannot change between W-2 and 1099 in place; create a new worker record"
      )
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

    it "reconstructs legacy Social Security taxable carry-forward from stored tax" do
      AnnualTaxConfig.find_or_initialize_by(tax_year: 2026).tap do |config|
        config.assign_attributes(
          ss_wage_base: 184_500,
          ss_rate: 0.062,
          medicare_rate: 0.0145,
          additional_medicare_rate: 0.009,
          additional_medicare_threshold: 200_000,
          is_active: false
        )
        config.save!
      end
      prior_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 1, 14),
        pay_date: Date.new(2026, 1, 16))
      current_period = create(:pay_period,
        company: company,
        start_date: Date.new(2026, 1, 15),
        end_date: Date.new(2026, 1, 28),
        pay_date: Date.new(2026, 1, 30))
      create(:payroll_item,
        employee: employee,
        company: company,
        pay_period: prior_period,
        gross_pay: 1_200.0,
        reported_tips: 200.0,
        social_security_tax: 62.0,
        social_security_taxable_wages: nil,
        social_security_taxable_tips: nil)

      totals = employee.ytd_totals_before(
        year: 2026,
        pay_date: current_period.pay_date,
        pay_period_id: current_period.id
      )

      expect(totals[:social_security_taxable_total]).to eq(1_000.0)
    end
  end
end
