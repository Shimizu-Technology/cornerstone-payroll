# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFieldInputBuilder do
  it "returns a field referenced by a saved payroll item after its employee is terminated" do
    company = create(:company)
    employee = create(:employee, company: company, status: "terminated", termination_date: Date.new(2026, 6, 5))
    pay_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 5, 18),
      end_date: Date.new(2026, 5, 31),
      pay_date: Date.new(2026, 6, 4)
    )
    payroll_item = create(:payroll_item, company: company, employee: employee, pay_period: pay_period)
    field = create(
      :payroll_field_definition,
      :employer_contribution,
      company: company,
      name: "Employer Benefit",
      amount_type: "fixed",
      show_in_payroll_grid: true
    )
    create(
      :payroll_item_field_entry,
      payroll_item: payroll_item,
      payroll_field_definition: field,
      label: field.name,
      kind: field.kind,
      tax_treatment: field.tax_treatment,
      category: field.category,
      amount: 12.34,
      source: "employee_default",
      employer_paid: true
    )

    result = described_class.new(pay_period: pay_period, company_id: company.id).call

    expect(result.fetch(:fields).pluck(:id)).to contain_exactly(field.id)
    expect(result.fetch(:assignments)).to be_empty
  end
  context "requested amounts and retained retirement entries" do
    let(:company) { create(:company) }
    let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
    let(:period) { create(:pay_period, company: company) }
    let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: period) }

    def retirement_entry(name:, source: "manual", amount: 40, requested: 400, definition_active: true, **assignment_options)
      field = create(:payroll_field_definition, company: company, name: name, kind: "deduction",
        tax_treatment: "pre_tax_deduction", category: "retirement", reporting_group: "401k_pre_tax", active: definition_active)
      employee.employee_payroll_fields.create!({ payroll_field_definition: field, amount: requested }.merge(assignment_options))
      create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, label: name,
        reporting_group: "401k_pre_tax", amount: amount, source: source, active: true,
        metadata: { "uncapped_amount" => requested.to_s })
    end

    def worksheet
      described_class.new(pay_period: period, company_id: company.id).call
    end

    it "exposes original requested amounts separately from applied amounts without modifying the saved row" do
      entry = retirement_entry(name: "Synthetic capped contribution")
      result = worksheet
      expect(result[:assignments]).to contain_exactly(include(requested_amount: 400.0, current_amount: 40.0))
      expect(result[:retained_manual_entries]).to be_empty
      expect(entry.reload).to have_attributes(amount: 40.to_d, metadata: { "uncapped_amount" => "400" })
    end

    it "identifies paused, future, expired, and inactive-definition manual/import retirement entries" do
      paused = retirement_entry(name: "Synthetic paused contribution", active: false)
      future = retirement_entry(name: "Synthetic future contribution", start_date: period.pay_date + 1)
      expired = retirement_entry(name: "Synthetic expired contribution", source: "import", end_date: period.pay_date - 1)
      inactive = retirement_entry(name: "Synthetic inactive definition", definition_active: false)
      retirement_entry(name: "Synthetic active contribution")
      result = worksheet
      expect(result[:retained_manual_entries]).to contain_exactly(*[ paused, future, expired, inactive ].map do |entry|
        include(employee_id: employee.id, field_id: entry.payroll_field_definition_id, label: entry.label,
          requested_amount: 400.0, applied_amount: 40.0, source: entry.source)
      end)
      expect(result[:retained_manual_entries].map { |entry| entry[:field_id] }).not_to include(result[:assignments].first[:payroll_field_definition_id])
    end

    it "does not warn about a hidden but effective assignment or an inactive paycheck entry" do
      hidden = retirement_entry(name: "Synthetic hidden contribution")
      hidden.payroll_field_definition.update!(show_in_payroll_grid: false)
      inactive = retirement_entry(name: "Synthetic inactive row", active: false)
      inactive.update!(active: false)
      expect(worksheet[:retained_manual_entries]).to be_empty
    end

    it "keeps capped-to-zero requests visible but removes a deliberately cleared request from the notice" do
      entry = retirement_entry(name: "Synthetic paused request", active: false)
      entry.update!(amount: 0)
      expect(worksheet[:retained_manual_entries]).to contain_exactly(include(requested_amount: 400.0, applied_amount: 0.0))
      entry.update!(metadata: {})
      expect(worksheet[:retained_manual_entries]).to be_empty
    end

    it "includes definition-less retirement imports but excludes unrelated manual deductions and other clients" do
      standalone = item.payroll_item_field_entries.create!(label: "Synthetic imported 401(k)", kind: "deduction",
        tax_treatment: "pre_tax_deduction", category: "retirement", amount: 50, source: "import", active: true,
        metadata: { "uncapped_amount" => "500" })
      item.payroll_item_field_entries.create!(label: "Synthetic rent", kind: "deduction",
        tax_treatment: "post_tax_deduction", category: "rent", amount: 50, source: "manual", active: true)
      other_company = create(:company)
      other_employee = create(:employee, company: other_company, department: create(:department, company: other_company))
      other_period = create(:pay_period, company: other_company)
      other_item = create(:payroll_item, company: other_company, employee: other_employee, pay_period: other_period)
      other_item.payroll_item_field_entries.create!(label: "Other synthetic 401(k)", kind: "deduction",
        tax_treatment: "pre_tax_deduction", category: "retirement", amount: 60, source: "manual", active: true)
      expect(worksheet[:retained_manual_entries]).to contain_exactly(include(field_id: nil,
        employee_id: employee.id, label: standalone.label, requested_amount: 500.0, applied_amount: 50.0, source: "import"))
    end
  end
end
