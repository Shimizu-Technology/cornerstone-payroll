# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFieldInputApplier do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company), date_of_birth: Date.new(1970, 1, 1)) }
  let(:period) { create(:pay_period, company: company) }
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: period, pay_rate: 100, hours_worked: 50) }
  let(:applier) { described_class.new(pay_period: period, company_id: company.id) }

  def assigned_field(amount:, name: "Synthetic retirement contribution")
    field = create(:payroll_field_definition, company: company, name: name, kind: "deduction",
      tax_treatment: "pre_tax_deduction", category: "retirement", reporting_group: "401k_pre_tax", default_amount: amount)
    assignment = employee.employee_payroll_fields.create!(payroll_field_definition: field, amount: amount, active: true)
    [ field, assignment ]
  end

  def capped_entry(field, amount: 60, requested: 600, source: "manual", metadata: {})
    item.payroll_item_field_entries.create!(payroll_field_definition: field, label: field.name, kind: field.kind,
      tax_treatment: field.tax_treatment, category: field.category, reporting_group: field.reporting_group,
      amount: amount, employee_paid: true, active: true, source: source,
      metadata: { "uncapped_amount" => requested.to_s }.merge(metadata))
  end

  def apply(field, amount:, **flags)
    applier.apply!(payroll_item: item, employee: employee,
      inputs: { field.id.to_s => { "mode" => "override", "amount" => amount }.merge(flags.stringify_keys) })
  end

  %w[manual import].each do |source|
    [ 60, 600 ].each do |echo|
      it "preserves the original #{source} request when the worksheet echoes #{echo}" do
        field, = assigned_field(amount: 600)
        entry = capped_entry(field, source: source, metadata: { "loan_requested_amount" => "650", "audit" => "keep" })
        apply(field, amount: echo)
        expect(entry.metadata).to include("uncapped_amount" => "600", "loan_requested_amount" => "650", "audit" => "keep")
      end
    end
  end

  it "preserves the original loan request when echoed separately from an intermediate capped amount" do
    field, = assigned_field(amount: 600)
    entry = capped_entry(field, metadata: { "loan_requested_amount" => "650" })
    apply(field, amount: 650, replace_request: false)
    expect(PayrollFieldRequestIntent.requested_amount(entry)).to eq(650)
    expect(entry.metadata).to include("uncapped_amount" => "600", "loan_requested_amount" => "650")
  end

  it "replaces request metadata when the operator changes the requested amount" do
    field, = assigned_field(amount: 600)
    entry = capped_entry(field, metadata: { "loan_requested_amount" => "650", "audit" => "keep" })
    apply(field, amount: 250)
    expect(entry).to have_attributes(amount: 250.to_d, metadata: { "audit" => "keep" })
  end

  it "allows an explicit zero to replace a request that was already capped to zero" do
    field, = assigned_field(amount: 600)
    entry = capped_entry(field, amount: 0, metadata: { "loan_requested_amount" => "650" })
    apply(field, amount: 0, replace_request: true)
    expect(entry.amount).to eq(0)
    expect(entry.metadata).not_to have_key("uncapped_amount")
    expect(entry.metadata).not_to have_key("loan_requested_amount")
  end

  it "retains a capped-to-zero request when an old client merely echoes its applied zero" do
    field, = assigned_field(amount: 600)
    entry = capped_entry(field, amount: 0)
    apply(field, amount: 0)
    expect(entry.metadata).to include("uncapped_amount" => "600")
  end

  [ "true", "false", 1, 0, nil ].each do |flag|
    it "rejects non-boolean replace_request #{flag.inspect} before modifying any input" do
      field, = assigned_field(amount: 600)
      entry = capped_entry(field)
      expect { apply(field, amount: 0, replace_request: flag) }.to raise_error(ArgumentError, /must be a JSON boolean/)
      expect(entry).to have_attributes(amount: 60.to_d, metadata: { "uncapped_amount" => "600" })
    end
  end

  context "normal retirement calculations" do
    before do
      create(:tax_table)
      allow(employee).to receive(:ytd_totals_before).and_return(gross_pay: 100_000, retirement: 22_800, roth_retirement: 0)
    end

    it "restores the request after an unrelated worksheet save and repeats it consistently once catch-up is verified" do
      regular, = assigned_field(amount: 400, name: "Synthetic regular deferral")
      catch_up, = assigned_field(amount: 600, name: "Synthetic additional deferral")
      capped_entry(catch_up, amount: 600)
      PayrollCalculator.for(employee, item).calculate
      entry = item.payroll_item_field_entries.find { |row| row.payroll_field_definition_id == catch_up.id }
      expect(entry.amount).to eq(120)
      expect(entry.metadata["uncapped_amount"].to_d).to eq(600)
      apply(catch_up, amount: entry.amount)
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      2.times { PayrollCalculator.for(employee, item).calculate }
      expect(entry.amount).to eq(600)
      expect(item.retirement_rule_snapshot.dig("requested", "traditional").to_d).to eq(1_000)
      expect(PayrollRetirementTotals.for_item(item)[:retirement]).to eq(1_000)
      expect(item.payroll_item_field_entries.find { |row| row.payroll_field_definition_id == regular.id }.amount).to eq(400)
    end

    it "keeps a manual request authoritative when an assignment for the same definition changes" do
      field, assignment = assigned_field(amount: 600)
      entry = capped_entry(field)
      assignment.update!(amount: 900)
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      PayrollCalculator.for(employee, item).calculate
      expect(item.payroll_item_field_entries.count { |row| row.payroll_field_definition_id == field.id }).to eq(1)
      expect(entry.amount).to eq(600)
    end

    it "shows retained manual intent rather than silently deduplicating a replacement definition" do
      old_field, old_assignment = assigned_field(amount: 600, name: "Synthetic earlier deferral")
      capped_entry(old_field)
      old_assignment.update!(active: false)
      replacement, = assigned_field(amount: 600, name: "Synthetic replacement deferral")
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      PayrollCalculator.for(employee, item).calculate
      expect(item.retirement_rule_snapshot.dig("requested", "traditional").to_d).to eq(1_200)
      expect(item.payroll_item_field_entries.find { |row| row.payroll_field_definition_id == replacement.id }.amount).to eq(600)
      item.save!
      retained = PayrollFieldInputBuilder.new(pay_period: period, company_id: company.id).call[:retained_manual_entries]
      expect(retained).to contain_exactly(include(field_id: old_field.id, requested_amount: 600.0, applied_amount: 600.0))
      expect(old_assignment.reload).not_to be_active
    end

    it "keeps a scheduled or paused assignment's saved manual entry visible and intact" do
      field, assignment = assigned_field(amount: 600)
      entry = capped_entry(field)
      assignment.update!(start_date: period.pay_date + 1)
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      PayrollCalculator.for(employee, item).calculate
      expect(entry).to have_attributes(amount: 600.to_d, active: true, source: "manual")
      item.save!
      retained = PayrollFieldInputBuilder.new(pay_period: period, company_id: company.id).call[:retained_manual_entries]
      expect(retained).to contain_exactly(include(field_id: field.id, requested_amount: 600.0))
    end
  end
end
