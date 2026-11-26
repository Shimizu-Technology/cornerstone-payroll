# frozen_string_literal: true

require_relative "parity_helper"

module Parity
  module PaycheckScenarios
    # Table-driven fixtures: each entry exercises a distinct payroll scenario from
    # the parity roster (no demo seed).
    LIST = [
      {
        label: "hourly_overtime (Period 2: 80h reg + 10h OT + 8h PTO + 8h Holiday, paper check)",
        employee_key: :hourly_overtime,
        item_key: :hourly_overtime_p2,
        period_reader: :period2,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: false
      },
      {
        label: "salaried_401k (Period 2: 4% 401k + 3% ER match, direct deposit, check_date offset)",
        employee_key: :salaried_401k,
        item_key: :salaried_401k_p2,
        period_reader: :period2,
        has_check_pdf: false,
        has_401k: true,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: true,
        is_correction: false,
        is_contractor: false
      },
      {
        label: "additional_withholding_med (Period 2: W-4 4c $75 + >$200k Additional Medicare, paper check)",
        employee_key: :additional_withholding_med,
        item_key: :additional_withholding_med_p2,
        period_reader: :period2,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: true,
        has_addl_medicare: true,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: false
      },
      {
        label: "prior_provider_ytd (Period 2: native check after QuickBooks bridge)",
        employee_key: :prior_provider_ytd,
        item_key: :prior_provider_ytd_p2,
        period_reader: :period2,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: false
      },
      {
        label: "corrective_paycheck (Supplemental delta check +20h)",
        employee_key: :corrective_paycheck,
        item_key: :corrective_delta,
        period_reader: :corrective_period,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: true,
        is_contractor: false
      },
      {
        label: "terminated_employee (Period 2 final check accessed via former employee link)",
        employee_key: :terminated_employee,
        item_key: :terminated_p2,
        period_reader: :period2,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: false
      },
      {
        label: "roth_401k (Period 2: 5% Roth 401k + 2% ER Roth match, paper check)",
        employee_key: :roth_401k,
        item_key: :roth_401k_p2,
        period_reader: :period2,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: true,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: false
      },
      {
        label: "native_non_taxable (Period 2: hourly + native $125 Uniform Reimbursement)",
        employee_key: :native_non_taxable,
        item_key: :native_non_taxable_p2,
        period_reader: :period2,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: true,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: false
      },
      {
        label: "true_contractor (Period 2: true 1099 contractor, zero taxes, net == gross)",
        employee_key: :true_contractor,
        item_key: :true_contractor_p2,
        period_reader: :period2,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: true
      },
      {
        label: "same_period_bonus (Period 1 bonus check — second check on same pay period & pay date)",
        employee_key: :same_period_bonus,
        item_key: :same_period_bonus_p1_bonus,
        period_reader: :period1_bonus,
        has_check_pdf: true,
        has_401k: false,
        has_roth_401k: false,
        has_non_taxable_pay: false,
        has_addl_wh: false,
        has_addl_medicare: false,
        has_check_date_offset: false,
        is_correction: false,
        is_contractor: false
      }
    ].freeze
  end
end

RSpec.describe "Paycheck figures parity across employee, client, staff, and PDF views", type: :request do
  include Parity::ParityContext

  Parity::PaycheckScenarios::LIST.each do |scenario|
    context scenario[:label] do
      let(:fixture_scenarios) { [ scenario[:employee_key] ] }
      let(:period) { fixture.public_send(scenario[:period_reader]) }
      let(:views) do
        extract_all_paycheck_views(
          employee_key: scenario[:employee_key],
          item_key: scenario[:item_key],
          period: period
        )
      end

      it "matches gross, net, taxes, hours, period dates, payment method, check number, and correction status across every view" do
        expected_views = %i[
          employee_api employee_stub_pdf
          client_pay_period client_pay_history client_stub_pdf
          staff_pay_period staff_pay_history
        ]
        expected_views << :check_stub_pdf if scenario[:has_check_pdf]
        expect(views.keys).to match_array(expected_views)

        core_figures = [
          :gross_pay,
          :net_pay,
          [ :taxes, :total_income_tax ],
          [ :taxes, :social_security ],
          [ :taxes, :medicare_total ],
          [ :taxes, :total_taxes ],
          [ :dates, :period_start ],
          [ :dates, :period_end ],
          [ :hours, :regular ],
          [ :hours, :overtime ],
          [ :hours, :combined ]
        ]
        core_figures << [ :dates, :pay_date ] unless scenario[:has_check_date_offset]

        assert_parity_table!(
          fixture: scenario[:employee_key],
          views: views,
          figures: core_figures
        )

        # PTO and Holiday hours appear on employee API, PDFs, pay histories, and staff pay period.
        leave_hours_views = views.slice(
          :employee_api, :employee_stub_pdf, :client_pay_history, :client_stub_pdf,
          :staff_pay_period, :staff_pay_history, :check_stub_pdf
        )
        assert_parity_table!(
          fixture: scenario[:employee_key],
          views: leave_hours_views,
          figures: [ [ :hours, :pto ], [ :hours, :holiday ] ]
        )

        # Printed tax TOTAL row on check stub PDF must match the sum of printed tax components.
        if scenario[:has_check_pdf] && !scenario[:is_contractor]
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :taxes, :printed_total_vs_components ],
            values_by_view: {
              check_stub_printed_total: views.dig(:check_stub_pdf, :taxes, :printed_total),
              check_stub_components_sum: views.dig(:check_stub_pdf, :taxes, :total_taxes),
              employee_api: views.dig(:employee_api, :taxes, :total_taxes)
            }
          )
        end

        if scenario[:is_contractor]
          expect(views.dig(:employee_api, :taxes, :total_taxes)).to eq(BigDecimal("0.00"))
          expect(views.dig(:employee_api, :net_pay)).to eq(views.dig(:employee_api, :gross_pay))
        end

        method_views = views.slice(:employee_api, :employee_stub_pdf, :client_pay_history, :client_stub_pdf, :staff_pay_period, :staff_pay_history)
        assert_parity!(
          fixture: scenario[:employee_key],
          figure: [ :payment, :method ],
          values_by_view: method_views.transform_values { |v| dig_figure(v, [ :payment, :method ]) }
        )

        if scenario[:has_check_pdf]
          # Separate view set includes check_stub_pdf (excluded from method_views since
          # check PDFs carry a printed check number rather than a payment.method field).
          check_number_views = views.slice(
            :employee_api, :employee_stub_pdf, :client_pay_history, :client_stub_pdf,
            :staff_pay_period, :staff_pay_history, :check_stub_pdf
          )
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :payment, :check_number ],
            values_by_view: check_number_views.transform_values { |v| dig_figure(v, [ :payment, :check_number ]) }
          )
        end

        status_views = views.slice(:employee_api, :client_pay_period, :client_pay_history, :staff_pay_period, :staff_pay_history)
        assert_parity!(
          fixture: scenario[:employee_key],
          figure: [ :status, :correction ],
          values_by_view: status_views.transform_values { |v| dig_figure(v, [ :status, :correction ]) }
        )
        expect(views.dig(:employee_api, :status, :correction)).to eq(scenario[:is_correction])

        if scenario[:has_401k]
          ded_views = views.slice(:employee_api, :employee_stub_pdf, :client_pay_period, :client_stub_pdf, :staff_pay_period)
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :deductions, :retirement_401k, :amount ],
            values_by_view: ded_views.transform_values { |v| dig_figure(v, [ :deductions, :retirement_401k, :amount ]) }
          )
          expect(views.dig(:employee_api, :deductions, :retirement_401k, :amount)).to be > 0
        end

        if scenario[:has_roth_401k]
          roth_views = views.slice(:employee_api, :employee_stub_pdf, :client_pay_period, :client_stub_pdf, :staff_pay_period, :check_stub_pdf)
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :deductions, :roth_401k, :amount ],
            values_by_view: roth_views.transform_values { |v| dig_figure(v, [ :deductions, :roth_401k, :amount ]) }
          )
          expect(views.dig(:employee_api, :deductions, :roth_401k, :amount)).to be > 0
        end

        if scenario[:has_non_taxable_pay]
          nontax_views = views.slice(:employee_api, :employee_stub_pdf, :client_pay_period, :client_stub_pdf, :staff_pay_period, :check_stub_pdf)
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: :non_taxable_pay,
            values_by_view: nontax_views.transform_values { |v| dig_figure(v, :non_taxable_pay) }
          )
          expect(views.dig(:employee_api, :non_taxable_pay)).to eq(BigDecimal("125.00"))
        end
      end

      if scenario[:has_check_date_offset]
        it "matches effective pay_date across all views even when check_date differs from pay_period.pay_date" do
          # Protect today's agreement within each group before the pending cross-group check.
          check_date_group = views.slice(:employee_api, :employee_stub_pdf, :client_stub_pdf)
          period_date_group = views.slice(:client_pay_period, :client_pay_history, :staff_pay_period, :staff_pay_history)
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :dates, :pay_date_check_date_group ],
            values_by_view: check_date_group.transform_values { |v| dig_figure(v, [ :dates, :pay_date ]) }
          )
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :dates, :pay_date_period_date_group ],
            values_by_view: period_date_group.transform_values { |v| dig_figure(v, [ :dates, :pay_date ]) }
          )

          pending "L11: employee API and PDFs show per-item check_date while client/staff pay periods and pay history show pay_period.pay_date"
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :dates, :pay_date ],
            values_by_view: views.transform_values { |v| dig_figure(v, [ :dates, :pay_date ]) }
          )
        end
      end

      if scenario[:has_401k]
        it "shows employer 401(k) match on employee API as well as PDFs and staff pay run" do
          # Protect today's agreement ($90.00) across PDFs and staff pay run before pending.
          agreeing_er_views = views.slice(:employee_stub_pdf, :client_stub_pdf, :staff_pay_period)
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :employer_contributions, :employer_401k_match, :amount ],
            values_by_view: agreeing_er_views.transform_values { |v| dig_figure(v, [ :employer_contributions, :employer_401k_match, :amount ]) }
          )
          expect(views.dig(:staff_pay_period, :employer_contributions, :employer_401k_match, :amount)).to eq(BigDecimal("90.00"))

          pending "L7: employer contributions appear on pay stub PDFs and staff pay run but are omitted from employee statements API"
          er_views = views.slice(:employee_api, :employee_stub_pdf, :client_stub_pdf, :staff_pay_period)
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :employer_contributions, :employer_401k_match, :amount ],
            values_by_view: er_views.transform_values { |v| dig_figure(v, [ :employer_contributions, :employer_401k_match, :amount ]) }
          )
        end
      end

      if scenario[:has_addl_wh]
        it "splits base income tax and W-4 4(c) additional withholding consistently across APIs and reports" do
          # Protect today's split agreement across the 6 views that separate base FIT and W-4 4(c).
          split_views = views.slice(
            :employee_api, :employee_stub_pdf, :client_pay_period,
            :client_stub_pdf, :staff_pay_period, :check_stub_pdf
          )
          assert_parity_table!(
            fixture: scenario[:employee_key],
            views: split_views,
            figures: [ [ :taxes, :income_tax ], [ :taxes, :additional_withholding ] ]
          )
          expect(views.dig(:employee_api, :taxes, :additional_withholding)).to eq(BigDecimal("75.00"))

          pending "L4: employee_pay_history reports combine FIT and W-4 4(c) additional withholding into withholding_tax while stubs and pay-period APIs split them"
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :taxes, :income_tax ],
            values_by_view: views.transform_values { |v| dig_figure(v, [ :taxes, :income_tax ]) }
          )
        end

        it "uses the full W-4 4(c) label on the employee statement and the compact label on check stock" do
          expect(views.dig(:employee_api, :tax_display_labels, :additional_withholding)).to eq("Additional Guam income tax (W-4 4c)")
          expect(views.dig(:employee_stub_pdf, :tax_labels, :additional_withholding)).to eq("Additional Guam income tax (W-4 4c)")
          expect(views.dig(:check_stub_pdf, :tax_labels, :additional_withholding)).to eq("Add'l Guam income tax (4c)")
        end
      end

      if scenario[:has_addl_medicare]
        it "breaks out Additional Medicare (0.9%) separately and does not label the combined amount 'Medicare (1.45%)'" do
          # Protect today's agreement between staff and client pay-period APIs on the Medicare split.
          assert_parity_table!(
            fixture: scenario[:employee_key],
            views: views.slice(:staff_pay_period, :client_pay_period),
            figures: [ [ :taxes, :medicare_base ], [ :taxes, :additional_medicare ], [ :taxes, :medicare_total ] ]
          )
          expect(views.dig(:staff_pay_period, :taxes, :additional_medicare)).to be > 0

          # When base Medicare (1.45%) and Additional Medicare (0.9%) are split into
          # separate lines, keeping 'Medicare (1.45%)' on the base line is valid;
          # reject '1.45%' only if it describes the combined amount without a separate line.
          if views.dig(:employee_stub_pdf, :taxes, :additional_medicare).nil?
            expect(views.dig(:employee_stub_pdf, :tax_labels, :medicare)).not_to include("1.45%")
          end
          med_views = views.slice(:staff_pay_period, :client_pay_period, :employee_api, :employee_stub_pdf, :check_stub_pdf)
          assert_parity_table!(
            fixture: scenario[:employee_key],
            views: med_views,
            figures: [ [ :taxes, :medicare_base ], [ :taxes, :additional_medicare ], [ :taxes, :medicare_total ] ]
          )
        end
      end
    end
  end

  describe "AIRE worker statements parity (EmployeePayStatements::Presenter)" do
    let(:fixture_scenarios) { %i[hourly_overtime roth_401k native_non_taxable] }
    let(:include_aire) { true }

    it "matches gross, net, non-taxable pay, taxes, deductions, combined hours, dates, check number, and YTD between AIRE worker statements and Employee/Client/Staff APIs" do
      [
        { employee_key: :hourly_overtime, item_key: :hourly_overtime_p2, period: fixture.period2 },
        { employee_key: :roth_401k, item_key: :roth_401k_p2, period: fixture.period2 },
        { employee_key: :native_non_taxable, item_key: :native_non_taxable_p2, period: fixture.period2 }
      ].each do |entry|
        item = fixture.items.fetch(entry[:item_key])
        views = extract_all_paycheck_views(
          employee_key: entry[:employee_key],
          item_key: entry[:item_key],
          period: entry[:period]
        )
        aire_view = aire_api(entry[:employee_key]).extract_paycheck(payroll_item_id: item.id)
        expect(aire_view.dig(:status, :visible)).to eq(true)

        compared = {
          aire_api: aire_view,
          employee_api: views.fetch(:employee_api),
          employee_stub_pdf: views.fetch(:employee_stub_pdf),
          staff_pay_period: views.fetch(:staff_pay_period)
        }
        assert_parity_table!(
          fixture: :"#{entry[:employee_key]}_aire",
          views: compared,
          figures: [
            :gross_pay,
            :net_pay,
            :non_taxable_pay,
            [ :taxes, :income_tax ],
            [ :taxes, :social_security ],
            [ :taxes, :medicare_total ],
            [ :taxes, :total_taxes ],
            [ :hours, :combined ],
            [ :dates, :period_start ],
            [ :dates, :period_end ],
            [ :dates, :pay_date ],
            [ :payment, :method ],
            [ :payment, :check_number ]
          ]
        )

        # AIRE and Employee API share the same as-of-check YTD totals.
        assert_parity_table!(
          fixture: :"#{entry[:employee_key]}_aire_ytd",
          views: { aire_api: aire_view, employee_api: views.fetch(:employee_api) },
          figures: [
            [ :ytd, :gross ],
            [ :ytd, :total_income_tax ],
            [ :ytd, :social_security ],
            [ :ytd, :medicare_total ],
            [ :ytd, :net ]
          ]
        )
      end
    end
  end

  describe "label and wording parity across views" do
    let(:fixture_scenarios) { %i[hourly_overtime salaried_401k] }

    it "uses one canonical Guam income tax label across employee API, employee PDF, and check stub PDF" do
      views = extract_all_paycheck_views(
        employee_key: :hourly_overtime,
        item_key: :hourly_overtime_p2,
        period: fixture.period2
      )

      assert_parity!(
        fixture: :hourly_overtime,
        figure: [ :tax_labels, :income_tax ],
        values_by_view: {
          employee_api_display: views.dig(:employee_api, :tax_display_labels, :income_tax),
          employee_api_raw: views.dig(:employee_api, :tax_labels, :income_tax),
          employee_stub_pdf: views.dig(:employee_stub_pdf, :tax_labels, :income_tax),
          employee_stub_pdf_ytd: views.dig(:employee_stub_pdf, :ytd_tax_labels, :income_tax),
          check_stub_pdf: views.dig(:check_stub_pdf, :tax_labels, :income_tax)
        }
      )
    end

    it "uses identical 401(k) pre-tax deduction labels on pay stub PDF and check stub PDF" do
      item = fixture.items.fetch(:salaried_401k_p2)
      emp_pdf = pay_stub_pdf_extractor.extract(
        employee_api(:salaried_401k).statement_pdf_bytes(fixture.ensure_stub_posted!(:salaried_401k_p2).id)
      )
      chk_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item).generate)

      # Amounts match today.
      assert_parity!(
        fixture: :salaried_401k,
        figure: [ :deductions, :retirement_401k, :amount ],
        values_by_view: {
          employee_stub_pdf: emp_pdf.dig(:deductions, :retirement_401k, :amount),
          check_stub_pdf: chk_pdf.dig(:deductions, :retirement_401k, :amount)
        }
      )

      pending "L14: pre-tax 401(k) label is '401(k) Retirement' on pay stub PDF / employee API vs '401(k) Pre-Tax' on check stub PDF"
      assert_parity!(
        fixture: :salaried_401k,
        figure: [ :deductions, :retirement_401k, :label ],
        values_by_view: {
          employee_stub_pdf: emp_pdf.dig(:deductions, :retirement_401k, :label),
          check_stub_pdf: chk_pdf.dig(:deductions, :retirement_401k, :label)
        }
      )
    end

    it "uses consistent observed payment-method wording across employee PDF, client PDF, and pay history" do
      dd_views = extract_all_paycheck_views(
        employee_key: :salaried_401k,
        item_key: :salaried_401k_p2,
        period: fixture.period2
      )

      # Structured-field check (not observed copy): Employee API exposes payment.method, not a label string.
      expect(dd_views.dig(:employee_api, :payment, :method)).to eq("direct_deposit")

      # Protect today's observed agreement between employee PDF and pay history before pending.
      assert_parity!(
        fixture: :salaried_401k,
        figure: [ :payment, :payment_label_agreeing ],
        values_by_view: {
          employee_stub_pdf: dd_views.dig(:employee_stub_pdf, :payment, :payment_label),
          client_pay_history: dd_views.dig(:client_pay_history, :payment, :payment_label),
          staff_pay_history: dd_views.dig(:staff_pay_history, :payment, :payment_label)
        }
      )

      pending "L12: direct deposit wording differs between employee PDF / pay history ('Direct deposit') and client PDF ('Direct deposit (stub only; transfer not confirmed)')"
      assert_parity!(
        fixture: :salaried_401k,
        figure: [ :payment, :payment_label ],
        values_by_view: {
          employee_stub_pdf: dd_views.dig(:employee_stub_pdf, :payment, :payment_label),
          client_stub_pdf: dd_views.dig(:client_stub_pdf, :payment, :payment_label),
          client_pay_history: dd_views.dig(:client_pay_history, :payment, :payment_label),
          staff_pay_history: dd_views.dig(:staff_pay_history, :payment, :payment_label)
        }
      )
    end
  end
end
