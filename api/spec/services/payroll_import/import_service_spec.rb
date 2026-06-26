# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::ImportService do
  let(:company) { create(:company) }
  let(:pay_period) { create(:pay_period, company: company) }
  let(:service) { described_class.new(pay_period) }

  describe "#apply!" do
    it "copies employee recurring payroll adjustments onto MoSa imported payroll items before calculating" do
      employee = create(
        :employee,
        company: company,
        first_name: "Sara",
        last_name: "Doctor",
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 225_062.76,
        default_payroll_adjustments: [
          { "label" => "Test taxable bonus", "amount" => 100.0, "treatment" => "taxable_addition", "active" => true },
          { "label" => "Test reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition", "active" => true },
          { "label" => "Test pre-tax deduction", "amount" => 10.0, "treatment" => "pre_tax_deduction", "active" => true },
          { "label" => "Test rent payment", "amount" => 15.0, "treatment" => "post_tax_deduction", "active" => true }
        ]
      )

      allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }

      result = service.apply!(
        matched: [
          {
            employee_id: employee.id,
            regular_hours: 0,
            overtime_hours: 0,
            total_tips: 0,
            loan_deduction: 200.0
          }
        ]
      )

      expect(result[:errors]).to be_empty
      payroll_item = pay_period.payroll_items.find_by!(employee: employee)
      expect(payroll_item.import_source).to eq("mosa_revel")
      expect(payroll_item.payroll_adjustments).to contain_exactly(
        include("label" => "Test taxable bonus", "amount" => 100.0, "treatment" => "taxable_addition"),
        include("label" => "Test reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition"),
        include("label" => "Test pre-tax deduction", "amount" => 10.0, "treatment" => "pre_tax_deduction"),
        include("label" => "Test rent payment", "amount" => 15.0, "treatment" => "post_tax_deduction")
      )
    end

    it "can import Excel tips as already-paid tip offsets for daily tip clients" do
      employee = create(
        :employee,
        company: company,
        first_name: "Tina",
        last_name: "Tips",
        employment_type: "hourly",
        pay_rate: 10.0
      )

      allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }

      result = service.apply!(
        matched: [
          {
            employee_id: employee.id,
            regular_hours: 40,
            overtime_hours: 0,
            total_tips: 75.0
          }
        ],
        tips_paid_out_from_tips: true
      )

      expect(result[:errors]).to be_empty
      payroll_item = pay_period.payroll_items.find_by!(employee: employee)
      expect(payroll_item.reported_tips).to eq(75.0)
      expect(payroll_item.tips_paid_out).to eq(75.0)
    end

    it "clears stale paid-out tip offsets when a re-import no longer marks tips as paid out" do
      employee = create(
        :employee,
        company: company,
        first_name: "Rita",
        last_name: "Reimport",
        employment_type: "hourly",
        pay_rate: 10.0
      )

      allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }

      first_result = service.apply!(
        matched: [
          {
            employee_id: employee.id,
            regular_hours: 40,
            overtime_hours: 0,
            total_tips: 100.0
          }
        ],
        tips_paid_out_from_tips: true
      )
      expect(first_result[:errors]).to be_empty

      second_result = service.apply!(
        matched: [
          {
            employee_id: employee.id,
            regular_hours: 40,
            overtime_hours: 0,
            total_tips: 40.0
          }
        ],
        force_overwrite: true,
        tips_paid_out_from_tips: false
      )

      expect(second_result[:errors]).to be_empty
      payroll_item = pay_period.payroll_items.find_by!(employee: employee)
      expect(payroll_item.reported_tips).to eq(40.0)
      expect(payroll_item.tips_paid_out).to eq(0.0)
    end
  end

  describe "#preview" do
    it "merges excel rows that fuzzy-match to the same employee" do
      employee = create(:employee, company: company, first_name: "Jane", last_name: "Doe")
      matcher = instance_double(PayrollImport::NameMatcher)

      allow(PayrollImport::NameMatcher).to receive(:new).and_return(matcher)
      allow(matcher).to receive(:match_excel_name).and_return({ employee_id: employee.id })

      result = service.preview(
        pdf_records: [],
        excel_records: [
          {
            first_name: "Jane", last_name: "Doe", total_tips: 10.0, tips_foh: 10.0,
            loan_deduction: 5.0, recurring_loan_deduction: 5.0, tip_pool: "foh"
          },
          {
            first_name: "J", last_name: "Doe", total_tips: 7.5, tips_boh: 7.5,
            loan_deduction: 2.5, installment_beginning_balance: 20.0,
            installment_new_amount: 5.0, installment_payment: 2.5,
            installment_estimated_ending_balance: 22.5, tip_pool: "boh"
          },
          {
            first_name: "Jane", last_name: "D.", total_tips: 0.0,
            loan_deduction: 1.5, installment_beginning_balance: 15.0,
            installment_new_amount: 2.0, installment_payment: 1.5,
            installment_estimated_ending_balance: 15.5
          }
        ]
      )

      expect(result[:matched]).to contain_exactly(
        include(
          employee_id: employee.id,
          total_tips: 17.5,
          tips_boh: 7.5,
          tips_foh: 10.0,
          loan_deduction: 9.0,
          recurring_loan_deduction: 5.0,
          installment_beginning_balance: 20.0,
          installment_new_amount: 7.0,
          installment_payment: 4.0,
          installment_estimated_ending_balance: 22.5,
          tip_pool: "mixed"
        )
      )
    end
  end
end
