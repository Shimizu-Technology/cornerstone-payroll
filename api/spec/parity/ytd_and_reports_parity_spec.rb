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

      it "prints the same as-of-check YTD on the check stub as the earnings statement, to the cent (L3)" do
        item = fixture.items.fetch(:hourly_overtime_p2)
        prior = fixture.items.fetch(:hourly_overtime_p1)
        # Independent of the code under test: the two committed paychecks' saved amounts.
        expected = ->(field) { (prior.public_send(field).to_d + item.public_send(field).to_d).round(2) }
        check_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item).generate)
        stub_pdf = pay_stub_pdf_extractor.extract(PayStubGenerator.new(item, employee_copy: true).generate)

        assert_parity_table!(
          fixture: :hourly_overtime,
          views: {
            saved_paychecks: {
              ytd: {
                gross: expected.call(:gross_pay),
                income_tax: expected.call(:withholding_tax),
                social_security: expected.call(:social_security_tax),
                medicare_total: expected.call(:medicare_tax),
                taxes_printed_total: %i[withholding_tax social_security_tax medicare_tax additional_withholding].sum(0.to_d) { |f| expected.call(f) }
              }
            },
            check_stub_pdf: check_pdf,
            employee_stub_pdf: stub_pdf.merge(ytd: stub_pdf[:ytd].merge(
              taxes_printed_total: %i[income_tax social_security medicare_total].sum(0.to_d) { |f| stub_pdf.dig(:ytd, f) }
            ))
          },
          figures: [ [ :ytd, :gross ], [ :ytd, :income_tax ], [ :ytd, :social_security ], [ :ytd, :medicare_total ], [ :ytd, :taxes_printed_total ] ]
        )
        expect(check_pdf.dig(:ytd, :gross)).to be > item.gross_pay.to_d
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

        # Both PDFs still list every current earning row (so a parsing failure
        # cannot pass as "no YTD") and both total the year in GROSS/TOTAL.
        expect(stub_pdf.fetch(:earnings)).not_to be_empty
        expect(check_pdf.fetch(:earnings).map { |row| row[:amount] }).to eq(stub_pdf.fetch(:earnings).map { |row| row[:amount] })
        expect(stub_pdf.fetch(:earnings)).to all(include(amount: be_present))
        assert_parity!(
          fixture: :hourly_overtime,
          figure: [ :ytd, :gross ],
          values_by_view: { employee_stub_pdf: stub_pdf.dig(:ytd, :gross), check_stub_pdf: check_pdf.dig(:ytd, :gross) }
        )
        # Neither prints a per-earning YTD the year cannot attribute.
        expect(stub_pdf.fetch(:earnings).map { |row| row[:ytd] }).to all(be_nil)
        expect(check_pdf.fetch(:earnings).map { |row| row[:ytd] }).to all(be_nil)
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
        # Every view counts the $150.00 QB non-taxable Reimbursement outside gross,
        # as the stub does: $1,810.00 taxable opening wages + $1,925.00 native.
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
        expect(emp_stmt.dig(:ytd, :gross)).to eq(BigDecimal("3735.00"))
        report = staff_api.ytd_summary(year: Parity::FixtureBuilder::TAX_YEAR)
        row = report.fetch("employees").find { |entry| entry["employee_id"] == employee.id }
        expect(money(row["non_taxable_additions_total"])).to eq(BigDecimal("150.00"))
        expect(row["imported_basis"]).to eq(UnifiedPayrollReporting::BRIDGED)
        expect(report.dig("source_summary", "historical_ytd_bridge", "totals_basis")).to eq(UnifiedPayrollReporting::BRIDGED)
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

        assert_parity!(
          fixture: :prior_provider_ytd,
          figure: [ :ytd, :total_income_tax ],
          values_by_view: {
            employee_api: emp_stmt.dig(:ytd, :total_income_tax),
            staff_ytd_summary: staff_ytd.dig(:ytd, :total_income_tax)
          }
        )
      end

      it "labels imported figures as imported when a date range covers only part of the bridge window" do
        employee = fixture.employees.fetch(:prior_provider_ytd)
        balance = fixture.qb_records.fetch(:ytd_balance)
        balance.update_columns(federal_income_tax: balance.federal_income_tax + BigDecimal("12.34"))
        row_for = lambda do |params|
          report = staff_api.ytd_summary_for(params)
          [ report.fetch("employees").find { |entry| entry["employee_id"] == employee.id }, report ]
        end

        # Full year: the bridge balance, as the stub and W-2GU read it.
        full_row, full_report = row_for.call(year: Parity::FixtureBuilder::TAX_YEAR)
        expect(full_row["imported_basis"]).to eq(UnifiedPayrollReporting::BRIDGED)
        expect(money(full_row["withholding_tax"])).to eq((balance.federal_income_tax + fixture.items.fetch(:prior_provider_ytd_p2).total_income_tax_withheld).round(2))
        expect(full_report.dig("source_summary", "historical_ytd_bridge", "totals_basis")).to eq(UnifiedPayrollReporting::BRIDGED)
        expect(staff_api.ytd_summary_pdf_text(year: Parity::FixtureBuilder::TAX_YEAR))
          .to include("Imported figures Gross, non-taxable pay, income tax, Social Security, Medicare, deductions and net pay from the applied opening YTD balance; other figures as imported")

        # A range that starts after January 1 cannot use a year-to-date balance.
        part_row, part_report = row_for.call(start_date: "2026-01-10", end_date: "2026-12-31")
        qb_check = fixture.qb_records.fetch(:paycheck)
        qb_adjustment = fixture.qb_records.fetch(:adjustment)
        expect(part_row["imported_basis"]).to eq(UnifiedPayrollReporting::AS_IMPORTED)
        expect(part_report.dig("source_summary", "historical_ytd_bridge", "totals_basis")).to eq(UnifiedPayrollReporting::AS_IMPORTED)
        expect(money(part_row["withholding_tax"])).to eq(
          (qb_check.federal_income_tax + qb_adjustment.federal_income_tax + fixture.items.fetch(:prior_provider_ytd_p2).total_income_tax_withheld).round(2)
        )
        # Either way the imported reimbursement sits outside gross.
        expect(money(part_row["gross_pay"])).to eq(money(full_row["gross_pay"]))
        expect(money(part_row["non_taxable_additions_total"])).to eq(BigDecimal("150.00"))
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
      let(:employee) { fixture.employees.fetch(:prior_provider_ytd) }
      let(:balance) { fixture.qb_records.fetch(:ytd_balance) }
      let(:later_item) { fixture.items.fetch(:prior_provider_ytd_p2) }
      let(:year) { Parity::FixtureBuilder::TAX_YEAR }

      # A native run paid inside the bridge window. Current guards refuse to
      # create or commit one (the first bridge needs a client with no pay
      # periods, and every period must follow the boundary), so this is older
      # data: the period skips only that check, then commits through the real
      # lifecycle. amounts: saved figures that repeat an imported paycheck.
      def overlap_run!(pay_date:, hours: BigDecimal("40.00"), amounts: nil, check_date: nil, employment_type: "hourly")
        period = PayPeriod.new(company: fixture.company, status: "approved",
          start_date: pay_date - 15, end_date: pay_date - 2, pay_date: pay_date)
        period.save!(validate: false)
        item = period.payroll_items.build(company: fixture.company, employee: employee, employment_type: "hourly",
          pay_rate: BigDecimal("22.00"), hours_worked: hours, payment_delivery_method: "direct_deposit")
        PayrollCalculator.for(employee, item).calculate
        item.save!
        allow_any_instance_of(PayPeriod).to receive(:starts_after_historical_ytd_boundary)
        TenantScope.with_company(fixture.company.id) do
          PayPeriodLifecycleService.new(pay_period: period, actor: fixture.staff_user).commit!
        end
        expect(period.reload).to be_committed
        # Older data whose saved figures differ from what a fresh calculation gives.
        updates = { **(amounts || {}), **(check_date ? { check_date: check_date } : {}), employment_type: employment_type }
        item.update_columns(**updates)
        item.reload
      end

      def w2_boxes
        row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: year)
        row.slice(:box1_wages, :box2_income_tax, :box3_ss_wages, :box4_ss_tax, :box5_medicare_wages, :box6_medicare_tax)
      end

      def statement_ytd
        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
      end

      def preflight_codes
        W2GuPreflightValidator.new(company: fixture.company, year: year).run.fetch(:findings).map { |finding| finding[:code] }
      end

      def overlaps
        PayrollBridgeOverlap.new(company_id: fixture.company.id, year: year).call
      end

      it "keeps counting as before, flags the run, and blocks W-2GU preflight, mark-ready and final files" do
        TenantScope.with_company(fixture.company.id) do
          FactoryBot.create(:payroll_filing_responsibility, :annual, company: fixture.company, tax_year: year,
            filing_type: "w2_gu", responsible_party: "cornerstone", imported_payroll_inclusion: "included", reviewed_by: fixture.staff_user)
        end
        before_boxes = w2_boxes
        before_statement = statement_ytd
        # Marked ready on today's inputs, as the fixture's own W-2GU posting does.
        ready_before = TenantScope.with_company(fixture.company.id) do
          snapshot = W2GuOfficialCopies.snapshot(fixture.company, year)
          W2FilingReadiness.find_or_initialize_by(company: fixture.company, year: year).update!(
            status: "filing_ready", preflight_fingerprint: snapshot.fetch(:fingerprint), ready_fingerprint: snapshot.fetch(:fingerprint),
            marked_ready_at: Parity::FixtureBuilder::POSTING_NOW, marked_ready_by: fixture.staff_user, notes: "Parity L16"
          )
          W2GuOfficialCopies.snapshot(fixture.company, year)
        end
        expect(ready_before[:final]).to eq(true)

        overlap_item = overlap_run!(pay_date: Date.new(2026, 1, 9))
        overlap = overlaps.sole
        expect([ overlap.payroll_item.id, overlap.proposal ]).to eq([ overlap_item.id, :distinct ])
        expect(overlap.evidence["suggestion"]).to eq("distinct")

        # Counting is exactly as before this change: the statement leaves the
        # run out, W-2GU counts it on top of the bridge.
        stmt = statement_ytd
        expect(stmt.dig(:ytd, :gross)).to eq(before_statement.dig(:ytd, :gross))
        expect(stmt.dig(:ytd, :gross)).to eq((balance.statement_gross_pay + later_item.gross_pay.to_d).round(2))
        after_boxes = w2_boxes
        expect(after_boxes[:box2_income_tax] - before_boxes[:box2_income_tax]).to eq(overlap_item.withholding_tax.to_d)

        # The statement says so, and filing is blocked everywhere.
        expect(employee_api(:prior_provider_ytd).statement_detail(fixture.ensure_stub_posted!(:prior_provider_ytd_p2).id)["ytd_note"])
          .to eq(PayrollBridgeOverlap::EMPLOYEE_NOTE)
        expect(preflight_codes).to include("BRIDGE_OVERLAP_NEEDS_DISPOSITION")
        expect(staff_api.post("/api/v1/admin/reports/w2_gu_preflight", year: year).first).to eq(200)
        status, body = staff_api.post("/api/v1/admin/reports/w2_gu_mark_ready", year: year)
        expect([ status, body["error"] ]).to eq([ 422, "Cannot mark filing ready with blocking findings" ])
        snapshot = TenantScope.with_company(fixture.company.id) { W2GuOfficialCopies.snapshot(fixture.company, year) }
        expect(snapshot[:fingerprint]).not_to eq(ready_before[:fingerprint])
        expect(snapshot[:final]).to eq(false)
        expect(W2GuOfficialCopies.final?(company: fixture.company, year: year, readiness: snapshot[:readiness],
          fingerprint: ready_before[:fingerprint])).to eq(false)
      end

      it "suggests a duplicate for a run repeating an imported paycheck, for review only" do
        qb_check = fixture.qb_records.fetch(:paycheck)
        before_boxes = w2_boxes
        duplicate = overlap_run!(pay_date: qb_check.pay_date, hours: BigDecimal("80.00"), amounts: {
          gross_pay: qb_check.gross_pay, net_pay: qb_check.net_pay, withholding_tax: qb_check.federal_income_tax,
          social_security_tax: qb_check.social_security_tax, medicare_tax: qb_check.medicare_tax
        })
        overlap = overlaps.sole
        expect([ overlap.proposal, overlap.matched_paycheck_id ]).to eq([ :duplicate, qb_check.id ])
        expect(overlap.evidence.dig("imported_paychecks", 0)).to include("same_pay_date" => true, "same_amounts" => true)

        # Nothing is applied from the suggestion: W-2GU still counts it and filing stays blocked.
        expect(w2_boxes[:box2_income_tax] - before_boxes[:box2_income_tax]).to eq(duplicate.withholding_tax.to_d)
        expect(preflight_codes).to include("BRIDGE_OVERLAP_NEEDS_DISPOSITION")
      end

      it "calls a run sharing the pay date but not the amounts ambiguous" do
        overlap_run!(pay_date: fixture.qb_records.fetch(:paycheck).pay_date)
        expect(overlaps.sole.proposal).to eq(:ambiguous)
        expect(preflight_codes).to include("BRIDGE_OVERLAP_NEEDS_DISPOSITION")
      end

      it "flags a run by its check date, and keeps a contractor's run out of the W-2GU block" do
        # The run is paid after the bridge, but its check is dated inside it.
        by_check_date = overlap_run!(pay_date: Date.new(2026, 1, 23), check_date: Date.new(2026, 1, 15))
        expect(overlaps.map { |row| row.payroll_item.id }).to eq([ by_check_date.id ])
        expect(overlaps.sole.evidence.dig("payroll_item", "paid_on")).to eq("2026-01-15")
        expect(preflight_codes).to include("BRIDGE_OVERLAP_NEEDS_DISPOSITION")

        by_check_date.update_columns(employment_type: "contractor")
        expect(overlaps.sole.blocks_w2?).to eq(false)
        expect(preflight_codes).not_to include("BRIDGE_OVERLAP_NEEDS_DISPOSITION")
        # Its statement note still shows: contractor YTD leaves the run out too.
        expect(PayrollBridgeOverlap.for_employee(employee: employee, year: year, through: later_item.pay_period.pay_date)).to be_present
      end
    end
  end
end
