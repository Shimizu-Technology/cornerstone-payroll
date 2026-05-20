# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::ImportService do
  let(:company) { create(:company) }
  let(:pay_period) { create(:pay_period, company: company) }
  let(:service) { described_class.new(pay_period) }

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
