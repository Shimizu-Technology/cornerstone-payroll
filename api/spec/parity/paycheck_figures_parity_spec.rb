# frozen_string_literal: true

require_relative "parity_helper"

RSpec.describe "Paycheck figures parity across employee, client, staff, and PDF views", type: :request do
  include Parity::ParityContext

  # Table-driven fixtures: each entry exercises a distinct payroll scenario from
  # the parity roster (no demo seed).
  PAYCHECK_SCENARIOS = [
    {
      label: "hourly_overtime (Period 2: 80h reg + 10h OT + 8h PTO, paper check)",
      employee_key: :hourly_overtime,
      item_key: :hourly_overtime_p2,
      period_reader: :period2,
      has_check_pdf: true,
      has_401k: false,
      has_addl_wh: false,
      has_addl_medicare: false,
      has_check_date_offset: false,
      is_correction: false
    },
    {
      label: "salaried_401k (Period 2: 4% 401k + 3% ER match, direct deposit, check_date offset)",
      employee_key: :salaried_401k,
      item_key: :salaried_401k_p2,
      period_reader: :period2,
      has_check_pdf: false,
      has_401k: true,
      has_addl_wh: false,
      has_addl_medicare: false,
      has_check_date_offset: true,
      is_correction: false
    },
    {
      label: "additional_withholding_med (Period 2: W-4 4c $75 + >$200k Additional Medicare, paper check)",
      employee_key: :additional_withholding_med,
      item_key: :additional_withholding_med_p2,
      period_reader: :period2,
      has_check_pdf: true,
      has_401k: false,
      has_addl_wh: true,
      has_addl_medicare: true,
      has_check_date_offset: false,
      is_correction: false
    },
    {
      label: "prior_provider_ytd (Period 2: native check after QuickBooks bridge)",
      employee_key: :prior_provider_ytd,
      item_key: :prior_provider_ytd_p2,
      period_reader: :period2,
      has_check_pdf: true,
      has_401k: false,
      has_addl_wh: false,
      has_addl_medicare: false,
      has_check_date_offset: false,
      is_correction: false
    },
    {
      label: "corrective_paycheck (Supplemental delta check +20h)",
      employee_key: :corrective_paycheck,
      item_key: :corrective_delta,
      period_reader: :corrective_period,
      has_check_pdf: true,
      has_401k: false,
      has_addl_wh: false,
      has_addl_medicare: false,
      has_check_date_offset: false,
      is_correction: true
    },
    {
      label: "terminated_employee (Period 1 accessed via former employee link)",
      employee_key: :terminated_employee,
      item_key: :terminated_p1,
      period_reader: :period1,
      has_check_pdf: true,
      has_401k: false,
      has_addl_wh: false,
      has_addl_medicare: false,
      has_check_date_offset: false,
      is_correction: false
    }
  ].freeze

  PAYCHECK_SCENARIOS.each do |scenario|
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
        %i[gross_pay net_pay].each do |field|
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: field,
            values_by_view: views.transform_values { |v| dig_figure(v, field) }
          )
        end

        [
          [ :taxes, :total_income_tax ],
          [ :taxes, :social_security ],
          [ :taxes, :medicare_total ],
          [ :taxes, :total_taxes ],
          [ :dates, :period_start ],
          [ :dates, :period_end ],
          [ :hours, :regular ],
          [ :hours, :overtime ],
          [ :hours, :combined ]
        ].each do |path|
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: path,
            values_by_view: views.transform_values { |v| dig_figure(v, path) }
          )
        end

        unless scenario[:has_check_date_offset]
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :dates, :pay_date ],
            values_by_view: views.transform_values { |v| dig_figure(v, [ :dates, :pay_date ]) }
          )
        end

        method_views = views.slice(:employee_api, :employee_stub_pdf, :client_pay_history, :client_stub_pdf, :staff_pay_period, :staff_pay_history)
        assert_parity!(
          fixture: scenario[:employee_key],
          figure: [ :payment, :method ],
          values_by_view: method_views.transform_values { |v| dig_figure(v, [ :payment, :method ]) }
        )

        if scenario[:has_check_pdf]
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :payment, :check_number ],
            values_by_view: method_views.transform_values { |v| dig_figure(v, [ :payment, :check_number ]) }
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
      end

      if scenario[:has_check_date_offset]
        it "matches effective pay_date across all views even when check_date differs from pay_period.pay_date" do
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
          pending "L4: employee_pay_history reports combine FIT and W-4 4(c) additional withholding into withholding_tax while stubs and pay-period APIs split them"
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :taxes, :income_tax ],
            values_by_view: views.transform_values { |v| dig_figure(v, [ :taxes, :income_tax ]) }
          )
        end

        it "uses the same W-4 4(c) additional withholding label across employee API, pay stub PDF, and check stub PDF" do
          pending "L17/F6: W-4 4(c) label differs across employee API display_label, pay stub PDF, and check stub PDF"
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :tax_labels, :additional_withholding ],
            values_by_view: {
              employee_api_display: views.dig(:employee_api, :tax_display_labels, :additional_withholding),
              employee_stub_pdf: views.dig(:employee_stub_pdf, :tax_labels, :additional_withholding),
              check_stub_pdf: views.dig(:check_stub_pdf, :tax_labels, :additional_withholding)
            }
          )
        end
      end

      if scenario[:has_addl_medicare]
        it "breaks out Additional Medicare (0.9%) separately and does not label the combined amount 'Medicare (1.45%)'" do
          # Sanity check that our fixture actually triggered real Additional Medicare (> $0).
          expect(views.dig(:staff_pay_period, :taxes, :additional_medicare)).to be > 0

          pending "L5: employee API and pay stub PDF label combined Medicare + Additional Medicare as 'Medicare (1.45%)' without a separate Additional Medicare line"
          expect(views.dig(:employee_stub_pdf, :tax_labels, :medicare)).not_to include("1.45%")
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :taxes, :additional_medicare ],
            values_by_view: {
              staff_pay_period: views.dig(:staff_pay_period, :taxes, :additional_medicare),
              client_pay_period: views.dig(:client_pay_period, :taxes, :additional_medicare),
              employee_api: views.dig(:employee_api, :taxes, :additional_medicare),
              employee_stub_pdf: views.dig(:employee_stub_pdf, :taxes, :additional_medicare),
              check_stub_pdf: views.dig(:check_stub_pdf, :taxes, :additional_medicare)
            }
          )
        end
      end
    end
  end

  describe "label and wording parity across views" do
    let(:fixture_scenarios) { %i[hourly_overtime salaried_401k] }

    it "uses one canonical Guam income tax label across employee API, employee PDF, and check stub PDF" do
      # Only need hourly_overtime for this label comparison.
      views = extract_all_paycheck_views(
        employee_key: :hourly_overtime,
        item_key: :hourly_overtime_p2,
        period: fixture.period2
      )

      pending "L17/F6: income tax label differs across employee API ('Guam income tax'), employee PDF ('Federal/Guam Income Tax' & 'Federal/Guam Tax'), and check stub PDF ('Federal Income Tax')"
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
      # Render a check stub for salaried_401k (via CheckGenerator) alongside PayStubGenerator PDF
      # to verify L14 deduction label parity on paper check stock as well as pay stub PDF.
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

    it "uses consistent payment-method wording across employee API, employee PDF, client PDF, and pay history" do
      dd_views = extract_all_paycheck_views(
        employee_key: :salaried_401k,
        item_key: :salaried_401k_p2,
        period: fixture.period2
      )

      pending "L12: direct deposit wording differs between employee PDF ('Direct deposit') and client PDF ('Direct deposit (stub only; transfer not confirmed)')"
      assert_parity!(
        fixture: :salaried_401k,
        figure: [ :payment, :payment_label ],
        values_by_view: {
          employee_api: dd_views.dig(:employee_api, :payment, :payment_label),
          employee_stub_pdf: dd_views.dig(:employee_stub_pdf, :payment, :payment_label),
          client_stub_pdf: dd_views.dig(:client_stub_pdf, :payment, :payment_label),
          staff_pay_history: dd_views.dig(:staff_pay_history, :payment, :payment_label)
        }
      )
    end
  end
end
