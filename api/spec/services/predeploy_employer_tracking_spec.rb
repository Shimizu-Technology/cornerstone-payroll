# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pre-deploy employer contribution tracking" do
  include_context "corrective payroll ledger fixtures"

  it "caps each same-label employee field through its saved mirror identity" do
    definitions = [ nil, employee ].map do |owner|
      create(:payroll_field_definition, company: company, owner_employee: owner, name: "Shared health", kind: "deduction",
        tax_treatment: "post_tax_deduction", category: "insurance", amount_type: "fixed", default_amount: 500)
    end
    definitions.each { |field| employee.employee_payroll_fields.create!(payroll_field_definition: field) }
    item = original!(post_liabilities: false)
    fields = item.payroll_item_field_entries.order(:id).to_a
    expect(fields.first.amount).to eq(500)
    expect(fields.last.amount).to be_between(0.01, 499.99)
    fields.each do |field|
      mirror = item.payroll_item_deductions.find_by!(deduction_type_id: field.metadata.dig("deduction_mirror", "deduction_type_id"))
      expect(mirror.amount).to eq(field.amount)
    end
    expect(item.net_pay).to eq(0)
    assert_cash(item)
  end

  %w[calculated approved].each do |status|
    it "rejects #{status} pre-deploy payroll before writes, then recalculates and commits" do
      field = create(:payroll_field_definition, company: company, name: "Employer health", kind: "employer_contribution",
        tax_treatment: "employer_contribution", category: "benefit", amount_type: "percentage", default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: field)
      period.update!(status: status)
      item = original!(post_liabilities: false, track_ytd: false)
      item.update_columns(calculation_context_snapshot: item.calculation_context_snapshot.except("built_in_employer_match_mirrors"))
      item.payroll_item_field_entries.each { |row| row.update_columns(metadata: row.metadata.except("deduction_mirror")) }
      frozen = freeze_history(item.reload)
      lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
      expect { status == "calculated" ? lifecycle.approve! : lifecycle.commit! }
        .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, "Recalculate this payroll — it was calculated before employer contribution tracking was added")
      expect(period.reload.status).to eq(status)
      expect(period.payroll_liability_postings).to be_empty
      expect(item.reload.check_number).to be_nil
      expect(employee.ytd_totals_for(2024).gross_pay).to eq(0)
      expect(freeze_history(item)).to eq(frozen)
      lifecycle.unapprove! if status == "approved"
      PayrollCalculator.for(employee, item).calculate
      item.save!
      lifecycle.approve!
      lifecycle.commit!
      expect(period.reload).to be_committed
      expect(PayrollLiabilityEntry.where(payroll_item_id: item.id, category: "benefit_employer").sum(:amount)).to eq(45)
    end
  end
end
