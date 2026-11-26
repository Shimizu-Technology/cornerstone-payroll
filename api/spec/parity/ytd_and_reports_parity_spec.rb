# frozen_string_literal: true

require_relative "parity_helper"

module Parity
  module YtdScenarios
    AS_OF_CHECK = [
      { employee_key: :hourly_overtime, item_key: :hourly_overtime_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :salaried_401k, item_key: :salaried_401k_p2, period_reader: :period2, has_check_pdf: false },
      { employee_key: :additional_withholding_med, item_key: :additional_withholding_med_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :prior_provider_ytd, item_key: :prior_provider_ytd_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :corrective_paycheck, item_key: :corrective_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :terminated_employee, item_key: :terminated_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :roth_401k, item_key: :roth_401k_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :native_non_taxable, item_key: :native_non_taxable_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :true_contractor, item_key: :true_contractor_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :same_period_bonus, item_key: :same_period_bonus_p2, period_reader: :period2, has_check_pdf: true }
    ].freeze

    # Ordinary employees (no prior-provider QuickBooks non-taxable reimbursement)
    # whose latest employee statement YTD must match client & staff ytd_summary
    # and the staff pay run ytd_gross / ytd_net snapshot today.
    ORDINARY_YEAR_END = [
      { employee_key: :hourly_overtime, latest_item_key: :hourly_overtime_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :salaried_401k, latest_item_key: :salaried_401k_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :additional_withholding_med, latest_item_key: :additional_withholding_med_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :corrective_paycheck, latest_item_key: :corrective_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :terminated_employee, latest_item_key: :terminated_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :roth_401k, latest_item_key: :roth_401k_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :native_non_taxable, latest_item_key: :native_non_taxable_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :same_period_bonus, latest_item_key: :same_period_bonus_p2, period_reader: :period2, w2_eligible: true },
      { employee_key: :reversed_paycheck, latest_item_key: :reversed_paycheck_p1, period_reader: :period1, w2_eligible: true },
      { employee_key: :true_contractor, latest_item_key: :true_contractor_p2, period_reader: :period2, w2_eligible: false }
    ].freeze
  end
end

RSpec.describe "YTD, historical QuickBooks, reports, and W-2GU parity", type: :request do
  include Parity::ParityContext

  describe "as-of-check YTD parity across employee API, pay stub PDFs, and check stub PDF" do
    Parity::YtdScenarios::AS_OF_CHECK.each do |scenario|
      context "for #{scenario[:employee_key]}" do
        let(:fixture_scenarios) { [ scenario[:employee_key] ] }

        it "matches as-of-check YTD totals across employee API, employee PDF, client PDF, and check stub PDF" do
          views = extract_all_paycheck_views(
            employee_key: scenario[:employee_key],
            item_key: scenario[:item_key],
            period: fixture.public_send(scenario[:period_reader])
          )
          statement_views = views.slice(:employee_api, :employee_stub_pdf, :client_stub_pdf, :check_stub_pdf)
          expected_keys = %i[employee_api employee_stub_pdf client_stub_pdf]
          expected_keys << :check_stub_pdf if scenario[:has_check_pdf]
          expect(statement_views.keys).to match_array(expected_keys)

          assert_parity_table!(
            fixture: scenario[:employee_key],
            views: statement_views,
            figures: [
              [ :ytd, :gross ],
              [ :ytd, :income_tax ],
              [ :ytd, :additional_withholding ],
              [ :ytd, :total_income_tax ],
              [ :ytd, :social_security ],
              [ :ytd, :medicare_total ],
              [ :ytd, :retirement_401k ],
              [ :ytd, :roth_401k ]
            ]
          )

          # Net YTD appears on employee API, employee PDF, and client PDF (check stub SUMMARY omits YTD net).
          net_views = views.slice(:employee_api, :employee_stub_pdf, :client_stub_pdf)
          assert_parity!(
            fixture: scenario[:employee_key],
            figure: [ :ytd, :net ],
            values_by_view: net_views.transform_values { |v| dig_figure(v, [ :ytd, :net ]) }
          )
        end
      end
    end

    context "CheckGenerator YTD source and earning attribution guards" do
      let(:fixture_scenarios) { [ :hourly_overtime ] }

      it "uses PayrollStatementYtdSources (BigDecimal) rather than Employee#ytd_totals_through float sums on CheckGenerator" do
        item = fixture.items.fetch(:hourly_overtime_p2)
        sources = PayrollStatementYtdSources.new(item)
        expected_sources_gross = (
          sources.items.sum(0.to_d) { |row| row.gross_pay.to_d } +
          (sources.historical_balance&.gross_pay.to_d || 0.to_d)
        ).round(2)
        check_gen = CheckGenerator.new(item)
        rendered_pdf = check_stub_pdf_extractor.extract(check_gen.generate)

        # Verify actual rendered YTD values on the check stub match PayrollStatementYtdSources.
        assert_parity!(
          fixture: :hourly_overtime,
          figure: [ :ytd, :gross_actual ],
          values_by_view: {
            check_stub_pdf: rendered_pdf.dig(:ytd, :gross),
            payroll_statement_ytd_sources: expected_sources_gross
          }
        )

        # L3 structural check: CheckGenerator currently computes YTD via Employee#ytd_totals_through
        # (which casts aggregates via to_f at employee.rb:622,702) instead of PayrollStatementYtdSources.
        fresh_gen = CheckGenerator.new(item)
        pending "L3: CheckGenerator#ytd uses Employee#ytd_totals_through (float sums) instead of PayrollStatementYtdSources"
        expect(PayrollStatementYtdSources).to receive(:new).with(item).at_least(:once).and_call_original
        expect(item.employee).not_to receive(:ytd_totals_through)
        refreshed_pdf = check_stub_pdf_extractor.extract(fresh_gen.generate)
        expect(refreshed_pdf.dig(:ytd, :gross)).to eq(expected_sources_gross)
      end

      it "gates unattributable per-earning YTD rows identically on check stub PDF and pay stub PDF" do
        # L8: Create a payroll item with an unattributable prior earning discrepancy
        # (stored earning omits a custom earning on a prior item) so PayStubGenerator
        # suppresses per-earning YTD with '—' while CheckGenerator prints it unchecked.
        item = fixture.items.fetch(:hourly_overtime_p2)
        prior = fixture.items.fetch(:hourly_overtime_p1)
        prior.update_columns(custom_earnings: [ { "label" => "Unstored Stipend", "amount" => "25.00" } ])

        stub_pdf = pay_stub_pdf_extractor.extract(PayStubGenerator.new(item, employee_copy: true).generate)
        check_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item).generate)

        stub_first_ytd = stub_pdf.fetch(:earnings).first&.fetch(:ytd)
        check_first_ytd = check_pdf.fetch(:earnings).first&.fetch(:ytd)

        pending "L8: CheckGenerator prints per-earning YTD unchecked while PayStubGenerator falls back to '—' when earnings cannot be attributed"
        assert_parity!(
          fixture: :hourly_overtime,
          figure: [ :earnings, 0, :ytd ],
          values_by_view: {
            employee_stub_pdf: stub_first_ytd,
            check_stub_pdf: check_first_ytd
          },
          allow_nil: true
        )
      end
    end
  end

  describe "YTD summary reports vs employee statement YTD parity" do
    it "matches employee latest-statement YTD against client ytd_summary, staff ytd_summary, staff pay run snapshot, and W-2GU Box 2 for all ordinary employees" do
      year = Parity::FixtureBuilder::TAX_YEAR
      Parity::YtdScenarios::ORDINARY_YEAR_END.each do |entry|
        key = entry[:employee_key]
        employee = fixture.employees.fetch(key)
        period = fixture.public_send(entry[:period_reader])
        doc = fixture.ensure_stub_posted!(entry[:latest_item_key])
        expect(doc).to be_present, "Expected posted latest pay stub for #{key}"

        emp_stmt = employee_api(key).extract_paycheck(statement_id: doc.id)
        cli_ytd = client_api.extract_ytd_summary_row(employee_id: employee.id, year: year)
        stf_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: year)
        stf_run = staff_api.extract_pay_run_item(pay_period_id: period.id, employee_id: employee.id)

        expect(cli_ytd).to be_present, "Missing client_ytd_summary row for #{key}"
        expect(stf_ytd).to be_present, "Missing staff_ytd_summary row for #{key}"
        expect(stf_run.dig(:status, :visible)).to eq(true), "Missing staff_pay_period item for #{key}"

        report_views = {
          employee_api: emp_stmt,
          client_ytd_summary: cli_ytd,
          staff_ytd_summary: stf_ytd
        }
        assert_parity_table!(
          fixture: key,
          views: report_views,
          figures: [
            [ :ytd, :gross ],
            [ :ytd, :total_income_tax ],
            [ :ytd, :social_security ],
            [ :ytd, :medicare_total ],
            [ :ytd, :retirement_401k ],
            [ :ytd, :roth_401k ],
            [ :ytd, :net ]
          ]
        )

        # Staff pay run YTD snapshot (ytd_gross / ytd_net) also matches employee statement YTD.
        assert_parity_table!(
          fixture: :"#{key}_run_snapshot",
          views: {
            employee_api: emp_stmt,
            staff_pay_period: stf_run,
            staff_ytd_summary: stf_ytd
          },
          figures: [ [ :ytd, :gross ], [ :ytd, :net ] ]
        )

        # Cross-check W-2GU Box 2/4/6/12 directly against the employee's last-stub YTD.
        w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: year)
        if entry[:w2_eligible]
          expect(w2_row).to be_present, "Missing W-2GU row for #{key}"
          assert_parity!(
            fixture: key,
            figure: :w2_box2_vs_employee_ytd_income_tax,
            values_by_view: {
              employee_api: emp_stmt.dig(:ytd, :total_income_tax),
              staff_w2_gu: w2_row[:box2_income_tax]
            }
          )
          assert_parity!(
            fixture: key,
            figure: :w2_box4_vs_employee_ytd_ss_tax,
            values_by_view: {
              employee_api: emp_stmt.dig(:ytd, :social_security),
              staff_w2_gu: w2_row[:box4_ss_tax]
            }
          )
          assert_parity!(
            fixture: key,
            figure: :w2_box6_vs_employee_ytd_medicare_tax,
            values_by_view: {
              employee_api: emp_stmt.dig(:ytd, :medicare_total),
              staff_w2_gu: w2_row[:box6_medicare_tax]
            }
          )
          assert_parity!(
            fixture: key,
            figure: :w2_box12_d_vs_employee_ytd_401k,
            values_by_view: {
              employee_api: emp_stmt.dig(:ytd, :retirement_401k),
              staff_w2_gu: w2_row[:box12_code_d]
            }
          )
          assert_parity!(
            fixture: key,
            figure: :w2_box12_aa_vs_employee_ytd_roth_401k,
            values_by_view: {
              employee_api: emp_stmt.dig(:ytd, :roth_401k),
              staff_w2_gu: w2_row[:box12_code_aa]
            }
          )
        else
          # True 1099 contractors must not appear on W-2GU.
          expect(w2_row).to be_nil
        end
      end
    end

    it "matches YTD summary reports between client and staff APIs for every employee" do
      year = Parity::FixtureBuilder::TAX_YEAR
      fixture.employees.each do |key, employee|
        cli = client_api.extract_ytd_summary_row(employee_id: employee.id, year: year)
        stf = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: year)
        expect(cli).to be_present, "Missing client_ytd_summary row for #{key}"
        expect(stf).to be_present, "Missing staff_ytd_summary row for #{key}"

        assert_parity_table!(
          fixture: key,
          views: { client_ytd_summary: cli, staff_ytd_summary: stf },
          figures: [
            [ :ytd, :gross ],
            [ :ytd, :total_income_tax ],
            [ :ytd, :social_security ],
            [ :ytd, :medicare_total ],
            [ :ytd, :retirement_401k ],
            [ :ytd, :roth_401k ],
            [ :ytd, :net ],
            [ :hours, :total_hours_field ],
            [ :hours, :overtime ],
            [ :hours, :combined ]
          ]
        )
      end
    end

    context "prior-provider QuickBooks and bridge scenarios" do
      let(:fixture_scenarios) { [ :prior_provider_ytd ] }

      it "reconciles prior-provider YTD gross across employee stub, client/staff YTD summary reports, and staff pay run snapshot (L2)" do
        employee = fixture.employees.fetch(:prior_provider_ytd)
        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        emp_stmt = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
        staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
        client_ytd = client_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
        staff_run = staff_api.extract_pay_run_item(pay_period_id: fixture.period2.id, employee_id: employee.id)

        expect(staff_ytd).to be_present
        expect(client_ytd).to be_present
        # Independent fixture precondition: bridge carries $150.00 non-taxable QB reimbursement.
        expect(fixture.qb_records.fetch(:ytd_balance).non_taxable_pay).to eq(BigDecimal("150.00"))
        # Today client/staff ytd_summary and staff_pay_period all agree with each other ($3,885.00),
        # while employee_api subtracts the $150.00 QB non-taxable Mileage Reimb ($3,735.00).
        assert_parity!(
          fixture: :prior_provider_ytd,
          figure: [ :ytd, :gross_report_and_run_group ],
          values_by_view: {
            client_ytd_summary: client_ytd.dig(:ytd, :gross),
            staff_ytd_summary: staff_ytd.dig(:ytd, :gross),
            staff_pay_period: staff_run.dig(:ytd, :gross)
          }
        )

        pending "L2: YTD summary reports and staff pay run ytd_gross include QuickBooks non-taxable reimbursements ($150.00) in gross_pay while pay stubs subtract them"
        assert_parity!(
          fixture: :prior_provider_ytd,
          figure: [ :ytd, :gross ],
          values_by_view: {
            employee_api: emp_stmt.dig(:ytd, :gross),
            client_ytd_summary: client_ytd.dig(:ytd, :gross),
            staff_ytd_summary: staff_ytd.dig(:ytd, :gross),
            staff_pay_period: staff_run.dig(:ytd, :gross)
          }
        )
      end

      it "uses the applied YTD bridge cutoff in YTD summary reports rather than summing raw imported paychecks without cutoff" do
        # L1: Simulate a bridge balance reconciled to a different FIT figure than raw locked QB check.
        employee = fixture.employees.fetch(:prior_provider_ytd)
        balance = fixture.qb_records.fetch(:ytd_balance)
        balance.update_columns(federal_income_tax: balance.federal_income_tax + BigDecimal("12.34"))

        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        emp_stmt = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
        staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
        expect(staff_ytd).to be_present

        pending "L1: YTD summary reports sum locked HistoricalPaycheck rows directly without honoring the applied HistoricalYtdBridge balance"
        assert_parity!(
          fixture: :prior_provider_ytd,
          figure: [ :ytd, :total_income_tax ],
          values_by_view: {
            employee_api: emp_stmt.dig(:ytd, :total_income_tax),
            staff_ytd_summary: staff_ytd.dig(:ytd, :total_income_tax)
          }
        )
      end

      it "represents adjusted QuickBooks paychecks consistently and clearly marks unadjusted as-imported rows in pay history" do
        employee = fixture.employees.fetch(:prior_provider_ytd)
        qb_check = fixture.qb_records.fetch(:paycheck)

        emp_qb = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: "qb-#{qb_check.id}")
        client_stubs = client_api.pay_stubs_index(employee.id).fetch("quickbooks_paychecks")
        client_qb = client_stubs.find { |row| row["id"].to_i == qb_check.id }
        staff_history = staff_api.employee_pay_history(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR).fetch("history")
        staff_qb_row = staff_history.find { |row| row["key"] == "imported:#{qb_check.id}" }
        staff_adj_rows = staff_history.select { |row| row["record_type"] == "adjustment" && row["historical_paycheck_id"].to_i == qb_check.id }

        expect(client_qb).to be_present
        expect(staff_qb_row).to be_present
        expect(staff_adj_rows).not_to be_empty

        # Employee API and Client Pay Stubs agree on the adjusted QB total ($1,960.00),
        # and staff pay history's imported row ($1,910.00) + adjustment row ($50.00) sum to $1,960.00.
        staff_combined_gross = money(staff_qb_row["gross_pay"]) + staff_adj_rows.sum(0.to_d) { |r| money(r["gross_pay"]) }
        assert_parity!(
          fixture: :prior_provider_ytd_qb,
          figure: :qb_adjusted_gross,
          values_by_view: {
            employee_api: emp_qb[:gross_pay],
            client_pay_stubs: money(client_qb["gross_pay"]),
            staff_pay_history_sum: staff_combined_gross.round(2)
          }
        )

        # PLAN.md §13 L15: staff/client pay history keeps the raw imported row + separate adjustment
        # row, so the imported row must clearly label that its original amount is as-imported / before adjustments.
        qb_label_text = [
          staff_qb_row.dig("source", "label"),
          staff_qb_row["period_description"],
          staff_qb_row["adjustment_note"],
          staff_qb_row["basis_label"]
        ].compact.join(" ")
        labeled_as_imported = qb_label_text.match?(/as imported|unadjusted|before adjustment|original.*adjust/i) ||
          staff_qb_row["as_imported"] == true ||
          money(staff_qb_row["gross_pay"]) == emp_qb[:gross_pay]

        pending "L15: staff/client pay history shows raw QuickBooks row ($1,910.00) without clearly labeling it as imported / unadjusted relative to its $50.00 adjustment row"
        expect(labeled_as_imported).to eq(true),
          "Expected staff pay history QB row (gross #{staff_qb_row['gross_pay']}) to label its original amount as imported/unadjusted or match adjusted gross (#{emp_qb[:gross_pay]}); got source=#{staff_qb_row['source'].inspect}, period_description=#{staff_qb_row['period_description'].inspect}"
      end
    end

    context "hours and unused helper checks" do
      let(:fixture_scenarios) { %i[hourly_overtime additional_withholding_med] }

      it "uses the same total_hours definition (combined hours) in YTD summary reports as in pay stubs and pay history rows" do
        employee = fixture.employees.fetch(:hourly_overtime)
        staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
        expect(staff_ytd).to be_present

        # Period 1 (80 reg + 4 OT + 8 Holiday) + Period 2 (80 reg + 10 OT + 8 PTO + 8 Holiday) = 198 combined.
        expect(staff_ytd.dig(:hours, :combined)).to eq(BigDecimal("198.00"))

        pending "L13: ytd_summary report sets `total_hours` to worked hours only (160.00) while `combined_hours` is 198.00"
        assert_parity!(
          fixture: :hourly_overtime,
          figure: [ :hours, :total_hours_vs_combined ],
          values_by_view: {
            ytd_summary_total_hours: staff_ytd.dig(:hours, :total_hours_field),
            ytd_summary_combined_hours: staff_ytd.dig(:hours, :combined)
          }
        )
      end

      it "removes or reconciles unused ReportsController#employee_ytd_summary and #employee_ytd_row" do
        controller = Api::V1::Admin::ReportsController.new
        allow(controller).to receive(:current_company_id).and_return(fixture.company.id)
        employee = fixture.employees.fetch(:additional_withholding_med)
        year = Parity::FixtureBuilder::TAX_YEAR
        real_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: year)
        expect(real_ytd.dig(:ytd, :total_income_tax)).to be > 0

        pending "L18: unused ReportsController#employee_ytd_summary / #employee_ytd_row drop W-4 4(c) additional_withholding and historical bridge balances"
        # Passes automatically when L18 deletes the unused private helpers (per PLAN.md),
        # or if they are kept and reconciled to match staff_ytd_summary.
        if controller.respond_to?(:employee_ytd_summary, true)
          helper_result = controller.send(:employee_ytd_summary, employee, year)
          assert_parity!(
            fixture: :additional_withholding_med,
            figure: [ :ytd, :total_income_tax ],
            values_by_view: {
              reports_controller_helper: money(helper_result[:withholding_tax]),
              staff_ytd_summary: real_ytd.dig(:ytd, :total_income_tax)
            }
          )
        end
        if controller.respond_to?(:employee_ytd_row, true)
          row_result = controller.send(:employee_ytd_row, employee, year)
          assert_parity!(
            fixture: :additional_withholding_med,
            figure: [ :ytd, :total_income_tax ],
            values_by_view: {
              reports_controller_row_helper: money(row_result[:withholding_tax]),
              staff_ytd_summary: real_ytd.dig(:ytd, :total_income_tax)
            }
          )
        end
      end
    end
  end

  describe "W-2GU and employee tax forms parity" do
    let(:include_w2_copies) { true }
    let(:fixture_scenarios) { %i[hourly_overtime salaried_401k roth_401k] }

    it "lists the posted 2026 W-2GU tax form and reconciles every official W-2GU PDF box (Copy B & Copy C) against the employee's last-stub YTD and Staff W-2GU JSON" do
      year = Parity::FixtureBuilder::TAX_YEAR
      [
        { key: :hourly_overtime, latest_item_key: :hourly_overtime_p2, expected_suffix: "JR" },
        { key: :salaried_401k, latest_item_key: :salaried_401k_p2, expected_suffix: "" },
        { key: :roth_401k, latest_item_key: :roth_401k_p2, expected_suffix: "" }
      ].each do |entry|
        key = entry[:key]
        employee = fixture.employees.fetch(key)
        forms = employee_api(key).tax_forms_list.fetch("tax_forms")
        form_2026 = forms.find { |f| f["tax_year"] == year }
        expect(form_2026).to be_present, "Expected 2026 W-2GU form listed for #{key}"
        expect(form_2026["pdf_available"]).to eq(true)

        w2_doc = fixture.w2_documents.fetch(key)
        w2_pdf = w2_gu_pdf_extractor.extract(employee_api(key).tax_form_pdf_bytes(w2_doc.id))
        w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: year)
        expect(w2_row).to be_present

        # Compare W-2GU PDF Copy B & Copy C coordinate boxes against Staff W-2GU JSON
        # AND directly against the employee's last posted pay stub YTD.
        stub_doc = fixture.ensure_stub_posted!(entry[:latest_item_key])
        emp_last_stub = employee_api(key).extract_paycheck(statement_id: stub_doc.id)
        emp_ytd_gross = emp_last_stub.dig(:ytd, :gross)
        emp_ytd_401k = emp_last_stub.dig(:ytd, :retirement_401k)
        emp_ytd_roth = emp_last_stub.dig(:ytd, :roth_401k)
        # Pre-tax 401(k) reduces Box 1 federal/Guam wages; Roth 401(k) does not.
        expected_from_stub = {
          box1_wages: (emp_ytd_gross - emp_ytd_401k).round(2),
          box2_income_tax: emp_last_stub.dig(:ytd, :total_income_tax),
          box3_ss_wages: [ emp_ytd_gross, BigDecimal("184500.00") ].min.round(2),
          box4_ss_tax: emp_last_stub.dig(:ytd, :social_security),
          box5_medicare_wages: emp_ytd_gross,
          box6_medicare_tax: emp_last_stub.dig(:ytd, :medicare_total),
          box12_code_d: emp_ytd_401k,
          box12_code_aa: emp_ytd_roth
        }

        assert_parity_table!(
          fixture: :"#{key}_w2_gu",
          views: {
            employee_last_stub_ytd: expected_from_stub,
            employee_w2_pdf_copy_b: w2_pdf.fetch(:copy_b),
            employee_w2_pdf_copy_c: w2_pdf.fetch(:copy_c),
            staff_w2_gu_json: w2_row
          },
          figures: %i[
            box1_wages box2_income_tax box3_ss_wages box4_ss_tax
            box5_medicare_wages box6_medicare_tax box12_code_d box12_code_aa
          ]
        )

        # W-2GU official form prints coded name suffix in its dedicated Box e Suff. box.
        expect(w2_pdf.dig(:copy_b, :suffix)).to eq(entry[:expected_suffix])
        expect(w2_pdf.dig(:copy_c, :suffix)).to eq(entry[:expected_suffix])
      end
    end

    context "native payroll on or before bridge cutoff (L16)" do
      let(:include_w2_copies) { false }
      let(:fixture_scenarios) { [ :prior_provider_ytd ] }

      it "does not double-count native payroll items dated on or before an applied historical bridge cutoff in W-2GU" do
        # L16: Add a native committed pay period dated on the exact bridge cutoff date for prior_provider_ytd.
        # PayrollStatementYtdSources excludes native items <= historical_cutoff, while YearEnd::W2PayrollItems
        # includes them alongside the bridge balance.
        employee = fixture.employees.fetch(:prior_provider_ytd)
        overlap_period = PayPeriod.new(
          company: fixture.company,
          status: "committed",
          start_date: Date.new(2026, 1, 1),
          end_date: Date.new(2026, 1, 14),
          pay_date: Parity::FixtureBuilder::QB_PERIOD_PAY,
          committed_at: Time.zone.parse("2026-01-16 09:00")
        )
        overlap_period.save!(validate: false)
        overlap_item = overlap_period.payroll_items.build(
          company: fixture.company,
          employee: employee,
          employment_type: "hourly",
          pay_rate: BigDecimal("22.00"),
          hours_worked: BigDecimal("40.00"),
          payment_delivery_method: "direct_deposit"
        )
        PayrollCalculator.for(employee, overlap_item).calculate
        overlap_item.save!

        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        emp_stmt = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
        w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
        expect(w2_row).to be_present

        pending "L16: YearEnd::W2PayrollItems includes native committed payroll dated <= historical_cutoff alongside the applied bridge balance, diverging from PayrollStatementYtdSources"
        assert_parity!(
          fixture: :prior_provider_ytd,
          figure: :w2_box2_vs_statement_ytd_income_tax,
          values_by_view: {
            employee_api_ytd: emp_stmt.dig(:ytd, :total_income_tax),
            staff_w2_gu_box2: w2_row[:box2_income_tax]
          }
        )
      end
    end
  end
end
