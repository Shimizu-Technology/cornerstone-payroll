# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Draft gross estimates shared with the worksheet" do
  cases = JSON.parse(Rails.root.join("../web/src/lib/__fixtures__/draft-gross.json").read)
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }

  cases.each do |scenario|
    it "matches the server calculator's gross for #{scenario.fetch('name')}" do
      employee = create(:employee, scenario.fetch("employee").symbolize_keys.merge(company: company))
      period = create(:pay_period, scenario.fetch("period").symbolize_keys.merge(company: company))
      input = scenario.fetch("item").deep_dup
      sources = input.delete("draft_earning_sources") || {}
      input["custom_columns_data"] = {
        PayrollItem::CUSTOM_EARNINGS_SOURCE_KEY => sources["custom_earnings"],
        PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY => sources["payroll_adjustments"],
        "payroll_adjustments_overridden" => sources["payroll_adjustments_overridden"]
      }.compact
      item = build(:payroll_item, input.symbolize_keys.merge(company: company, employee: employee,
        pay_period: period, employment_type: employee.employment_type, pay_rate: employee.pay_rate))
      hours = scenario.fetch("hours")
      item.hours_worked = hours.fetch("regular", 0)
      item.overtime_hours = hours.fetch("overtime", 0)
      item.wage_rate_hours = hours["wage_rates"] if hours["wage_rates"]
      item.salary_override = scenario["salaryOverride"] if scenario.key?("salaryOverride")
      item.bonus = scenario["bonus"] if scenario.key?("bonus")
      item.reported_tips = scenario["reportedTips"] if scenario.key?("reportedTips")
      item.tips_paid_out = scenario["tipsPaidOut"] if scenario.key?("tipsPaidOut")
      item.sync_default_custom_earnings!(employee)
      item.sync_default_payroll_adjustments!(employee)
      scenario.fetch("fields").each do |field_input|
        field = create(:payroll_field_definition, company: company, name: "Contract #{field_input.fetch('id')}",
          kind: "addition", tax_treatment: "taxable_addition", amount_type: field_input.fetch("amountType"),
          default_amount: field_input["amount"], default_percentage: field_input["percentage"], show_in_payroll_grid: !field_input["automatic"])
        employee.employee_payroll_fields.create!(payroll_field_definition: field, amount: nil, percentage: nil)
        if field_input.fetch("mode") == "override"
          PayrollFieldInputApplier.new(pay_period: period, company_id: company.id).apply!(payroll_item: item,
            employee: employee, inputs: { field.id.to_s => { mode: "override", amount: field_input.fetch("amount") } })
        elsif field_input["source"] == "import"
          item.payroll_item_field_entries.build(payroll_field_definition: field, label: field.name,
            kind: "addition", tax_treatment: "taxable_addition", category: field.category,
            amount: field_input.fetch("currentAmount"), source: "import", active: field_input.fetch("currentActive", true))
        end
      end
      # Use the real strategy's entire calculation, including base-before-percentage,
      # default synchronization, salary overtime and tip normalization. No duplicate
      # expectation formula is implemented in this spec.
      PayrollCalculator.for(employee, item).calculate
      expect(item.gross_pay.to_f).to eq(scenario.fetch("expected"))
    end
  end
end
