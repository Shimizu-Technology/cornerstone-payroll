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

      create(:payroll_item, pay_period: pay_period, employee: employee,
        employment_type: "salary", pay_rate: employee.pay_rate, salary_override: 1000, import_source: "mosa_revel")

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

    it "applies separate owner period pay and typed one-time components with source evidence" do
      employee = create(
        :employee,
        company: company,
        first_name: "Mo",
        last_name: "Owner",
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 0
      )
      allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }

      result = service.apply!(
        matched: [
          {
            employee_id: employee.id,
            regular_hours: 0,
            overtime_hours: 0,
            total_tips: 0,
            period_pay: 9_000,
            period_pay_evidence: {
              scope: "THIS EMPLOYEE ONLY",
              effective_pay_date: pay_period.pay_date.iso8601,
              source: "Approved owner instruction"
            },
            payroll_components: [
              {
                component_type: "REIMBURSEMENT",
                label: "Travel reimbursement",
                amount: 150,
                kind: "addition",
                tax_treatment: "non_taxable_addition",
                category: "reimbursement",
                effective_pay_date: pay_period.pay_date.iso8601,
                source: "Approved receipt"
              },
              {
                component_type: "POST-TAX DEDUCTION",
                label: "Uniform repayment",
                amount: 20,
                kind: "deduction",
                tax_treatment: "post_tax_deduction",
                category: "other",
                payee_name: "MoSa",
                effective_pay_date: pay_period.pay_date.iso8601,
                source: "Signed instruction"
              }
            ]
          }
        ]
      )

      expect(result[:errors]).to be_empty
      payroll_item = pay_period.payroll_items.find_by!(employee: employee)
      expect(payroll_item.salary_override).to eq(9_000.to_d)
      expect(payroll_item.custom_columns_data.fetch("period_pay_evidence")).to include(
        "scope" => "THIS EMPLOYEE ONLY",
        "amount" => "9000.0",
        "source" => "Approved owner instruction",
        "employee_id" => employee.id
      )
      expect(payroll_item.payroll_item_field_entries).to contain_exactly(
        have_attributes(label: "Travel reimbursement", amount: 150.to_d, tax_treatment: "non_taxable_addition", source: "import"),
        have_attributes(label: "Uniform repayment", amount: 20.to_d, tax_treatment: "post_tax_deduction", source: "import")
      )
      expect(payroll_item.payroll_item_field_entries.find_by!(label: "Uniform repayment").metadata).to include("payee_name" => "MoSa", "source" => "Signed instruction")
    end

    it "rejects workbook period pay for a fixed-pay employee" do
      employee = create(:employee, company: company, employment_type: "salary", salary_type: "per_period", pay_rate: 1_000)

      result = service.apply!(
        matched: [ { employee_id: employee.id, period_pay: 9_000, total_tips: 0 } ]
      )

      expect(result[:success]).to be_empty
      expect(result[:errors].first[:error]).to include("only allowed for variable-pay salary employees")
      expect(pay_period.payroll_items.where(employee: employee)).to be_empty
    end

    it "does not reuse period pay evidence from a replaced change workbook" do
      employee = create(
        :employee,
        company: company,
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 0
      )
      existing = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "salary",
        pay_rate: 0,
        salary_override: 9_000,
        import_source: "mosa_revel",
        custom_columns_data: {
          "period_pay_evidence" => {
            "amount" => "9000.0",
            "source_type" => "mosa_change_workbook"
          }
        }
      )

      expect {
        service.apply!(matched: [ { employee_id: employee.id, regular_hours: 0, overtime_hours: 0, total_tips: 0 } ])
      }.to raise_error(ArgumentError, /Enter Pay this period/)
      expect(existing.reload.salary_override).to eq(9_000.to_d)
    end

    [ nil, BigDecimal("0.00") ].each do |replacement_amount|
      label = replacement_amount.nil? ? "omitted" : "zero"

      it "clears workbook period pay when a replacement value is #{label}" do
        pay_period.update!(includes_base_salary: false)
        employee = create(
          :employee,
          company: company,
          employment_type: "salary",
          salary_type: "variable",
          pay_rate: 0
        )
        existing = create(
          :payroll_item,
          pay_period: pay_period,
          employee: employee,
          employment_type: "salary",
          pay_rate: 0,
          salary_override: BigDecimal("9000.00"),
          import_source: "mosa_revel",
          custom_columns_data: {
            "period_pay_evidence" => {
              "amount" => "9000.0",
              "source_type" => "mosa_change_workbook"
            }
          }
        )
        allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }
        row = { employee_id: employee.id, total_tips: BigDecimal("0.00") }
        row[:period_pay] = replacement_amount unless replacement_amount.nil?

        result = service.apply!(matched: [ row ])

        expect(result[:errors]).to be_empty
        expect(existing.reload.salary_override).to be_nil
        expect(existing.custom_columns_data).not_to have_key("period_pay_evidence")
      end
    end

    it "replaces imported one-time components authoritatively on re-import" do
      employee = create(:employee, company: company, employment_type: "hourly", pay_rate: 20)
      allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }
      component = {
        component_type: "BONUS",
        label: "Launch bonus",
        amount: 100,
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        effective_pay_date: pay_period.pay_date.iso8601,
        source: "CEO approval"
      }

      first = service.apply!(matched: [ { employee_id: employee.id, total_tips: 0, payroll_components: [ component ] } ])
      second = service.apply!(matched: [ { employee_id: employee.id, total_tips: 0, payroll_components: [] } ])

      expect(first[:errors]).to be_empty
      expect(second[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee).payroll_item_field_entries.where(source: "import")).to be_empty
    end

    it "preserves existing imported components when a replacement component is invalid" do
      employee = create(:employee, company: company, employment_type: "hourly", pay_rate: 20)
      payroll_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 20,
        import_source: "mosa_revel"
      )
      existing = payroll_item.payroll_item_field_entries.create!(
        label: "Approved reimbursement",
        kind: "addition",
        tax_treatment: "non_taxable_addition",
        category: "reimbursement",
        amount: BigDecimal("75.00"),
        employee_paid: true,
        employer_paid: false,
        source: "import"
      )

      result = service.apply!(matched: [
        {
          employee_id: employee.id,
          total_tips: BigDecimal("0.00"),
          payroll_components: [
            {
              component_type: "REIMBURSEMENT",
              label: "Invalid replacement",
              amount: BigDecimal("-10.00"),
              kind: "addition",
              tax_treatment: "non_taxable_addition",
              category: "reimbursement"
            }
          ]
        }
      ])

      expect(result[:errors].first[:error]).to match(/must be positive/i)
      expect(existing.reload).to be_persisted
      expect(payroll_item.payroll_item_field_entries.where(source: "import").pluck(:label)).to eq([ "Approved reimbursement" ])
    end

    it "rolls back a valid component replacement when payroll calculation fails" do
      employee = create(:employee, company: company, employment_type: "hourly", pay_rate: 20)
      payroll_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 20,
        import_source: "mosa_revel"
      )
      existing = payroll_item.payroll_item_field_entries.create!(
        label: "Approved reimbursement",
        kind: "addition",
        tax_treatment: "non_taxable_addition",
        category: "reimbursement",
        amount: BigDecimal("75.00"),
        employee_paid: true,
        employer_paid: false,
        source: "import"
      )
      allow_any_instance_of(PayrollItem).to receive(:calculate!).and_raise(ArgumentError, "Calculation stopped")

      result = service.apply!(matched: [
        {
          employee_id: employee.id,
          total_tips: BigDecimal("0.00"),
          payroll_components: [
            {
              component_type: "REIMBURSEMENT",
              label: "Replacement reimbursement",
              amount: BigDecimal("100.00"),
              kind: "addition",
              tax_treatment: "non_taxable_addition",
              category: "reimbursement",
              effective_pay_date: pay_period.pay_date.iso8601,
              source: "Approved receipt"
            }
          ]
        }
      ])

      expect(result[:errors].first[:error]).to eq("Calculation stopped")
      expect(existing.reload).to be_persisted
      expect(payroll_item.payroll_item_field_entries.where(source: "import").pluck(:label)).to eq([ "Approved reimbursement" ])
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

    it "uses the legacy workbook-level tip setting when the per-employee answer is blank" do
      employee = create(:employee, company: company, employment_type: "hourly", pay_rate: 10.0)
      allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }

      result = service.apply!(
        matched: [
          {
            employee_id: employee.id,
            regular_hours: 40,
            overtime_hours: 0,
            total_tips: 75.0,
            tips_already_paid: nil
          }
        ],
        tips_paid_out_from_tips: true
      )

      expect(result[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee).tips_paid_out).to eq(75.0)
    end

    it "lets an explicit per-employee answer override the legacy workbook-level tip setting" do
      employee = create(:employee, company: company, employment_type: "hourly", pay_rate: 10.0)
      allow_any_instance_of(PayrollItem).to receive(:calculate!) { |item| item.save! }

      result = service.apply!(
        matched: [
          {
            employee_id: employee.id,
            regular_hours: 40,
            overtime_hours: 0,
            total_tips: 75.0,
            tips_already_paid: false
          }
        ],
        tips_paid_out_from_tips: true
      )

      expect(result[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee).tips_paid_out).to eq(0.0)
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
    it "routes a reconciled recurring workbook amount through the named ledger instead of a direct scalar" do
      employee = create(:employee, company: company, first_name: "Mo", last_name: "Owner")
      deduction_type = DeductionType.create!(company: company, name: "Owner recurring repayment", category: "post_tax", sub_category: "loan")
      loan = EmployeeLoan.create!(
        company: company,
        employee: employee,
        deduction_type: deduction_type,
        name: "Owner recurring repayment",
        tracking_mode: "recurring_no_balance",
        payment_amount: 50,
        first_deduction_date: pay_period.pay_date
      )
      employee.employee_deductions.create!(deduction_type: deduction_type, amount: 50, active: true)

      result = service.preview(
        pdf_records: [ { employee_name: "Owner, Mo", regular_hours: 0 } ],
        excel_records: [ { employee_id: employee.id, loan_deduction: 50, recurring_loan_deduction: 50 } ]
      )

      expect(result[:can_apply]).to be(true)
      expect(result[:matched]).to contain_exactly(include(
        employee_id: employee.id,
        loan_deduction: 0.0,
        loan_reconciliation_errors: [],
        loan_reconciliation_matches: [ include(employee_loan_id: loan.id, amount: 50.to_d) ]
      ))
    end

    it "blocks a legacy recurring workbook amount until its named ledger exists" do
      employee = create(:employee, company: company, first_name: "Sarah", last_name: "Owner")

      result = service.preview(
        pdf_records: [ { employee_name: "Owner, Sarah", regular_hours: 0 } ],
        excel_records: [ { employee_id: employee.id, loan_deduction: 50, recurring_loan_deduction: 50 } ]
      )

      expect(result[:can_apply]).to be(false)
      expect(result[:matched].first[:loan_reconciliation_errors]).to include(/Set up the named recurring deduction/)
    end

    it "uses a separate workbook amount as the variable employee's period pay" do
      employee = create(
        :employee,
        company: company,
        first_name: "Sara",
        last_name: "Owner",
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 0
      )

      result = service.preview(
        pdf_records: [ { employee_name: "Owner, Sara", regular_hours: 0 } ],
        excel_records: [ { employee_id: employee.id, period_pay: 8_500, period_pay_evidence: { source: "Owner instruction" } } ]
      )

      expect(result[:can_apply]).to be(true)
      expect(result[:matched]).to contain_exactly(include(
        employee_id: employee.id,
        period_pay: 8_500,
        period_pay_evidence: { source: "Owner instruction" },
        current_period_pay: "8500.0",
        period_pay_source: "change_workbook",
        period_pay_missing: false
      ))
    end

    it "keeps a generated one-payroll deduction available when no named loan is due" do
      employee = create(:employee, company: company, first_name: "Avery", last_name: "Example")

      result = service.preview(
        pdf_records: [ { employee_name: "Example, Avery", regular_hours: 40 } ],
        excel_records: [ { employee_id: employee.id, loan_deduction: 20, one_payroll_deduction: 20 } ]
      )

      expect(result[:can_apply]).to be(true)
      expect(result[:matched]).to contain_exactly(include(loan_deduction: 20.0, loan_reconciliation_errors: []))
    end

    it "never resolves a stable employee ID from another client" do
      create(:employee, company: company, first_name: "Avery", last_name: "Example")
      other_employee = create(:employee, company: create(:company), first_name: "Outside", last_name: "Worker")

      result = service.preview(
        pdf_records: [],
        excel_records: [
          { employee_id: other_employee.id, employee_name: other_employee.full_name, total_tips: 50.0 }
        ]
      )

      expect(result[:matched]).to be_empty
      expect(result[:unmatched_excel_names]).to eq([ other_employee.full_name ])
      expect(result[:can_apply]).to be(false)
    end

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

    it "accounts for unmatched workbook rows instead of silently discarding their money" do
      create(:employee, company: company, first_name: "Avery", last_name: "Example")

      result = service.preview(
        pdf_records: [
          {
            employee_name: "Example, Avery",
            regular_hours: 40.0,
            overtime_hours: 2.0,
            regular_pay: 4_000.0,
            overtime_pay: 500.0,
            total_pay: 4_500.0
          }
        ],
        excel_records: [
          { first_name: "Missing", last_name: "Worker", total_tips: 117.50, loan_deduction: 123.50 }
        ]
      )

      expect(result).to include(
        unmatched_pdf_names: [],
        unmatched_excel_names: [ "Missing Worker" ],
        can_apply: false
      )
      expect(result[:matched].first).not_to include(:regular_pay, :overtime_pay, :total_pay)
      expect(result[:matched].first).to include(regular_hours: 40.0, overtime_hours: 2.0)
    end

    it "flags suggested typo matches for explicit review while keeping every source row" do
      employee = create(:employee, company: company, first_name: "Rosie", last_name: "Petirus")

      result = service.preview(
        pdf_records: [ { employee_name: "Petrius, Rosie", regular_hours: 37.5 } ],
        excel_records: [ { first_name: "Rosie", last_name: "Petrius", total_tips: 117.50 } ]
      )

      expect(result).to include(
        unmatched_pdf_names: [],
        unmatched_excel_names: [],
        can_apply: true
      )
      expect(result[:matched]).to contain_exactly(include(employee_id: employee.id, total_tips: 117.50))
      expect(result[:low_confidence_matches]).to contain_exactly(
        include(source: "Tips/loans workbook", source_name: "Rosie Petrius", employee_id: employee.id),
        include(source: "Revel hours", source_name: "Petrius, Rosie", employee_id: employee.id)
      )
    end

    it "blocks duplicate source rows that resolve to one employee" do
      employee = create(:employee, company: company, first_name: "Avery", last_name: "Example")

      result = service.preview(
        pdf_records: [
          { employee_name: "Example, Avery", regular_hours: 20.0 },
          { employee_name: "Example, Avery J.", regular_hours: 20.0 }
        ],
        excel_records: []
      )

      expect(result[:can_apply]).to be(false)
      expect(result[:duplicate_employee_matches]).to contain_exactly(
        employee_id: employee.id,
        employee_name: employee.full_name,
        source_names: [ "Example, Avery", "Example, Avery J." ]
      )
    end
  end
end
