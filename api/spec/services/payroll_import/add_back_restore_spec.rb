# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::AddBackRestore do
  let(:company) { create(:company) }
  let(:staff) { create(:user, company: company, role: "admin") }
  let(:period) { create(:pay_period, company: company, status: "calculated") }
  let(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Monroe", pay_rate: 35) }
  let(:component) do
    { component_type: "POST-TAX DEDUCTION", label: "Uniform repayment", amount: 20, kind: "deduction",
      tax_treatment: "post_tax_deduction", category: "other", payee_name: "MoSa",
      effective_pay_date: period.pay_date.iso8601, source: "Signed instruction" }
  end
  let(:row) do
    { employee_id: employee.id, employee_name: employee.full_name, workbook_only: true, regular_hours: 0, overtime_hours: 0,
      total_tips: 12.5, tips_already_paid: true, loan_deduction: 0, one_payroll_deduction: 0, recurring_loan_deduction: 0,
      loan_reconciliation_matches: [], bonus: 75, period_pay: nil, payroll_components: [ component ] }
  end

  def applied_import!(matched_row = row, raw_data: { "tips_paid_out_from_tips" => false })
    session = create(:payroll_intake_session, company: company, pay_period: period, source_type: "mosa_revel",
      source_label: PayrollIntake::Adapters::MosaRevel::SOURCE_LABEL, parser_version: PayrollIntake::Adapters::MosaRevel::PARSER_VERSION,
      status: "applied", applied_at: Time.current)
    create(:payroll_intake_row, payroll_intake_session: session, employee: employee, status: "applied", disposition: "included",
      dispositioned_at: Time.current, regular_hours: 0, week1_hours: 0, week2_hours: 0, week1_tips: 0, week2_tips: 0, reported_tips: 0, tips_paid_out: 0)
    PayrollImportRecord.create!(pay_period: period, payroll_intake_session: session, status: "applied", raw_data: raw_data,
      matched_data: [ matched_row ])
  end

  def call = described_class.new(pay_period: period, employee: employee, actor: staff).call

  before { allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! } }

  it "rebuilds tips, bonus and one-time items without hours, as the import applied them" do
    record = applied_import!

    result = call

    expect(result).to include(import_id: record.id, employee_name: "Avery Monroe", not_restored: [])
    expect(result[:restored].map { |entry| entry.values_at(:kind, :amount) })
      .to contain_exactly([ "tips", "12.5" ], [ "bonus", "75.0" ], [ "component", "20.0" ])
    item = period.payroll_items.find_by!(employee: employee)
    expect(item).to have_attributes(hours_worked: 0, overtime_hours: 0, reported_tips: 12.5.to_d, tips_paid_out: 12.5.to_d,
      bonus: 75.to_d, bonus_source: "mosa_revel", import_source: "mosa_revel")
    expect(item.payroll_item_field_entries.map { |entry| entry.attributes.slice("label", "amount", "source") })
      .to contain_exactly("label" => "Uniform repayment", "amount" => 20.to_d, "source" => "import")
    expect(item.custom_columns_data).to include("mosa_missing_revel_hours" => true,
      "mosa_imported_hours" => { "regular_hours" => "0.0", "overtime_hours" => "0.0" },
      "import_add_back" => include("import_id" => record.id, "added_back_by_id" => staff.id))
  end

  it "leaves out a one-time item apply would now refuse, and restores the rest" do
    applied_import!(row.merge(payroll_components: [ component.merge(effective_pay_date: (period.pay_date - 14).iso8601) ]))

    result = call

    expect(result[:not_restored]).to contain_exactly(key: "component:0", kind: "component", label: "Uniform repayment", amount: "20.0", enter_by_hand: true,
      reason: "Imported components must use this payroll's pay date. Add it in Edit payroll.")
    expect(result[:restored].map { |entry| entry[:kind] }).to contain_exactly("tips", "bonus")
    expect(period.payroll_items.find_by!(employee: employee).payroll_item_field_entries).to be_empty
  end

  it "never restores the workbook's Pay this period" do
    applied_import!(row.merge(total_tips: 0, bonus: nil, payroll_components: [], period_pay: "8807.5"))

    result = call

    expect(result[:restored]).to be_empty
    expect(result[:not_restored]).to contain_exactly(key: "period_pay", kind: "period_pay", label: "Pay this period", amount: "8807.5", enter_by_hand: true,
      reason: "Pay this period isn't brought back from the import. Enter Pay this period in Expected entries.")
    expect(period.payroll_items.find_by(employee: employee)).to be_nil
  end

  it "doesn't touch a payroll row that already exists" do
    applied_import!
    existing = create(:payroll_item, pay_period: period, employee: employee, reported_tips: 0)

    result = call

    expect(result[:restored]).to be_empty
    expect(result[:not_restored].map { |entry| entry[:kind] }).to contain_exactly("tips", "bonus", "component")
    # The existing row may already hold them, so nothing is sent to hand entry.
    expect(result[:not_restored].pluck(:enter_by_hand)).to all(be(false))
    expect(existing.reload.reported_tips).to eq(0)
  end

  it "returns nil when the applied import didn't include the worker" do
    record = applied_import!
    record.payroll_intake_session.rows.update_all(disposition: "excluded", disposition_reason: "Not paid here")

    expect(call).to be_nil
  end
end
