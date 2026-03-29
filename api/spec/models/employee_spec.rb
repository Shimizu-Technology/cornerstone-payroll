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
end
