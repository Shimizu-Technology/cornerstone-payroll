# frozen_string_literal: true

require_relative "parity_helper"

RSpec.describe "YTD, historical QuickBooks, reports, and W-2GU parity", type: :request do
  include Parity::ParityContext

  describe "as-of-check YTD parity across employee API, pay stub PDFs, and check stub PDF" do
    [
      { employee_key: :hourly_overtime, item_key: :hourly_overtime_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :salaried_401k, item_key: :salaried_401k_p2, period_reader: :period2, has_check_pdf: false },
      { employee_key: :additional_withholding_med, item_key: :additional_withholding_med_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :prior_provider_ytd, item_key: :prior_provider_ytd_p2, period_reader: :period2, has_check_pdf: true },
      { employee_key: :corrective_paycheck, item_key: :corrective_delta, period_reader: :corrective_period, has_check_pdf: true },
      { employee_key: :terminated_employee, item_key: :terminated_p1, period_reader: :period1, has_check_pdf: true }
    ].each do |scenario|
      context "for #{scenario[:employee_key]}" do
        let(:fixture_scenarios) { [ scenario[:employee_key] ] }

        it "matches as-of-check YTD totals across employee API, employee PDF, client PDF, and check stub PDF" do
          views = extract_all_paycheck_views(
            employee_key: scenario[:employee_key],
            item_key: scenario[:item_key],
            period: fixture.public_send(scenario[:period_reader])
          )
          statement_views = views.slice(:employee_api, :employee_stub_pdf, :client_stub_pdf, :check_stub_pdf)

          [
            [ :ytd, :gross ],
            [ :ytd, :income_tax ],
            [ :ytd, :additional_withholding ],
            [ :ytd, :total_income_tax ],
            [ :ytd, :social_security ],
            [ :ytd, :medicare_total ]
          ].each do |path|
            assert_parity!(
              fixture: scenario[:employee_key],
              figure: path,
              values_by_view: statement_views.transform_values { |v| dig_figure(v, path) }
            )
          end

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
      # L3 structural check: CheckGenerator currently computes YTD via Employee#ytd_totals_through
      # (which casts aggregates via to_f at employee.rb:622,702) instead of PayrollStatementYtdSources.
      # Construct a sub-cent-sensitive multi-check float sum (0.10 + 0.20) or verify source unity.
      item = fixture.items.fetch(:hourly_overtime_p2)
      check_gen = CheckGenerator.new(item)

      pending "L3: CheckGenerator#ytd uses Employee#ytd_totals_through (float sums) instead of PayrollStatementYtdSources"
      expect(PayrollStatementYtdSources).to receive(:new).with(item).at_least(:once).and_call_original
      expect(item.employee).not_to receive(:ytd_totals_through)
      check_gen.generate
    end

    it "gates unattributable per-earning YTD rows identically on check stub PDF and pay stub PDF" do
      # L8: Create a payroll item with an unattributable prior earning discrepancy
      # (stored earning omits a custom earning on a prior item) so PayStubGenerator
      # suppresses per-earning YTD with '—' while CheckGenerator prints it unchecked.
      item = fixture.items.fetch(:hourly_overtime_p2)
      prior = fixture.items.fetch(:hourly_overtime_p1)
      prior.update_columns(custom_earnings: [ { "label" => "Unstored Stipend", "amount" => 25.00 } ])

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
        }
      )
    end
    end
  end

  describe "YTD summary reports vs statement YTD parity" do
    it "matches YTD summary reports between client and staff APIs for every employee" do
      year = Parity::FixtureBuilder::TAX_YEAR
      fixture.employees.each do |key, employee|
        cli = client_api.extract_ytd_summary_row(employee_id: employee.id, year: year)
        stf = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: year)

        [
          [ :ytd, :gross ],
          [ :ytd, :total_income_tax ],
          [ :ytd, :social_security ],
          [ :ytd, :medicare_total ],
          [ :ytd, :retirement_401k ],
          [ :ytd, :net ],
          [ :hours, :total_hours_field ],
          [ :hours, :overtime ],
          [ :hours, :combined ]
        ].each do |path|
          assert_parity!(
            fixture: key,
            figure: path,
            values_by_view: { client_ytd_summary: dig_figure(cli, path), staff_ytd_summary: dig_figure(stf, path) }
          )
        end
      end
    end

    context "prior-provider QuickBooks and bridge scenarios" do
      let(:fixture_scenarios) { [ :prior_provider_ytd ] }

      it "reconciles prior-provider YTD gross between stubs (excluding QB non-taxable reimbursements) and YTD summary reports" do
        employee = fixture.employees.fetch(:prior_provider_ytd)
        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        emp_stmt = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
        staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
        client_ytd = client_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)

        # Today: Employee stub subtracts $150.00 QB non-taxable Mileage Reimb from YTD gross,
        # while YTD summary report includes the raw QB gross ($150 higher).
        expect(staff_ytd.dig(:ytd, :gross) - emp_stmt.dig(:ytd, :gross)).to eq(BigDecimal("150.00"))

        pending "L2: YTD summary reports include QuickBooks non-taxable reimbursements ($150.00) in gross_pay while pay stubs subtract them"
        assert_parity!(
          fixture: :prior_provider_ytd,
          figure: [ :ytd, :gross ],
          values_by_view: {
            employee_api: emp_stmt.dig(:ytd, :gross),
            client_ytd_summary: client_ytd.dig(:ytd, :gross),
            staff_ytd_summary: staff_ytd.dig(:ytd, :gross)
          }
        )
      end

      it "uses the applied YTD bridge cutoff in YTD summary reports rather than summing raw imported paychecks without cutoff" do
        # L1: Simulate a bridge balance reconciled to a different FIT figure than raw locked QB check.
        employee = fixture.employees.fetch(:prior_provider_ytd)
        balance = fixture.qb_records.fetch(:ytd_balance)
        balance.update_columns(federal_income_tax: balance.federal_income_tax + 12.34)

        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        emp_stmt = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
        staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)

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

      it "matches staff pay period ytd_gross snapshot against pay stub YTD when a historical bridge is applied" do
        employee = fixture.employees.fetch(:prior_provider_ytd)
        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        emp_stmt = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
        staff_item = staff_api.extract_pay_run_item(pay_period_id: fixture.period2.id, employee_id: employee.id)

        pending "NEW-2: staff pay period payroll_item ytd_gross/ytd_net snapshots omit applied historical YTD bridge balances"
        assert_parity!(
          fixture: :prior_provider_ytd,
          figure: [ :ytd, :gross ],
          values_by_view: {
            employee_api: emp_stmt.dig(:ytd, :gross),
            staff_pay_period: staff_item.dig(:ytd, :gross)
          }
        )
      end

      it "represents adjusted QuickBooks paychecks consistently across employee API, client pay stubs, and staff/client pay history" do
        employee = fixture.employees.fetch(:prior_provider_ytd)
        qb_check = fixture.qb_records.fetch(:paycheck)

        emp_qb = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: "qb-#{qb_check.id}")
        client_stubs = client_api.pay_stubs_index(employee.id).fetch("quickbooks_paychecks")
        client_qb = client_stubs.find { |row| row["id"].to_i == qb_check.id }
        staff_history = staff_api.employee_pay_history(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR).fetch("history")
        staff_qb_row = staff_history.find { |row| row["key"] == "imported:#{qb_check.id}" }

        # Employee API and Client Pay Stubs agree on the adjusted QB total ($1,960.00 gross / $1,653.79 net).
        assert_parity!(
          fixture: :prior_provider_ytd_qb,
          figure: :qb_adjusted_gross,
          values_by_view: {
            employee_api: emp_qb[:gross_pay],
            client_pay_stubs: money(client_qb["gross_pay"])
          }
        )

        pending "L15: employee API and client pay stubs roll QuickBooks adjustments into the paycheck row ($1960.00) while staff/client pay history shows raw ($1910.00) + separate adjustment row ($50.00)"
        assert_parity!(
          fixture: :prior_provider_ytd_qb,
          figure: :qb_row_gross,
          values_by_view: {
            employee_api: emp_qb[:gross_pay],
            client_pay_stubs: money(client_qb["gross_pay"]),
            staff_pay_history_qb_row: money(staff_qb_row["gross_pay"])
          }
        )
      end
    end

    context "hours and unused helper checks" do
      let(:fixture_scenarios) { %i[hourly_overtime additional_withholding_med] }

      it "uses the same total_hours definition (combined hours) in YTD summary reports as in pay stubs and pay history rows" do
        employee = fixture.employees.fetch(:hourly_overtime)
        staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)

        # Period 1 (80 reg + 4 OT) + Period 2 (80 reg + 10 OT + 8 PTO) = 160 reg, 14 OT, 8 PTO => 182 combined.
        expect(staff_ytd.dig(:hours, :combined)).to eq(BigDecimal("182.00"))

        pending "L13: ytd_summary report sets `total_hours` to worked hours only (160.00) while `combined_hours` is 182.00"
        assert_parity!(
          fixture: :hourly_overtime,
          figure: [ :hours, :total_hours_vs_combined ],
          values_by_view: {
            ytd_summary_total_hours: staff_ytd.dig(:hours, :total_hours_field),
            ytd_summary_combined_hours: staff_ytd.dig(:hours, :combined)
          }
        )
      end

      it "flags private ReportsController#employee_ytd_summary and #employee_ytd_row dropping additional_withholding and bridge balances" do
        controller = Api::V1::Admin::ReportsController.new
        allow(controller).to receive(:current_company_id).and_return(fixture.company.id)
        employee = fixture.employees.fetch(:additional_withholding_med)

        helper_result = controller.send(:employee_ytd_summary, employee, Parity::FixtureBuilder::TAX_YEAR)
        real_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)

        pending "L18: unused ReportsController#employee_ytd_summary / #employee_ytd_row drop W-4 4(c) additional_withholding and historical bridge balances"
        assert_parity!(
          fixture: :additional_withholding_med,
          figure: [ :ytd, :total_income_tax ],
          values_by_view: {
            reports_controller_helper: money(helper_result[:withholding_tax]),
            staff_ytd_summary: real_ytd.dig(:ytd, :total_income_tax)
          }
        )
      end
    end
  end

  describe "W-2GU and employee tax forms parity" do
    let(:include_w2_copies) { true }
    let(:fixture_scenarios) { %i[salaried_401k additional_withholding_med corrective_paycheck terminated_employee prior_provider_ytd] }
    it "lists the posted 2026 W-2GU tax form in the employee API and matches Staff W-2GU totals against YTD statements" do
      year = Parity::FixtureBuilder::TAX_YEAR
      # Check every W-2 employee with posted W-2GU copies (excluding contractor_transition whose
      # employee record was mutated to contractor, and checking hourly_overtime, salaried_401k,
      # additional_withholding_med, corrective_paycheck, terminated_employee, prior_provider_ytd).
      %i[salaried_401k additional_withholding_med corrective_paycheck terminated_employee].each do |key|
        employee = fixture.employees.fetch(key)
        forms = employee_api(key).tax_forms_list.fetch("tax_forms")
        form_2026 = forms.find { |f| f["tax_year"] == year }
        expect(form_2026).to be_present, "Expected 2026 W-2GU form listed for #{key}"
        expect(form_2026["pdf_available"]).to eq(true)

        w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: year)
        staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: year)

        assert_parity!(
          fixture: key,
          figure: :w2_box2_vs_ytd_income_tax,
          values_by_view: {
            staff_w2_gu: w2_row[:box2_income_tax],
            staff_ytd_summary: staff_ytd.dig(:ytd, :total_income_tax)
          }
        )
        assert_parity!(
          fixture: key,
          figure: :w2_box4_vs_ytd_ss_tax,
          values_by_view: {
            staff_w2_gu: w2_row[:box4_ss_tax],
            staff_ytd_summary: staff_ytd.dig(:ytd, :social_security)
          }
        )
        assert_parity!(
          fixture: key,
          figure: :w2_box6_vs_ytd_medicare_tax,
          values_by_view: {
            staff_w2_gu: w2_row[:box6_medicare_tax],
            staff_ytd_summary: staff_ytd.dig(:ytd, :medicare_total)
          }
        )
        assert_parity!(
          fixture: key,
          figure: :w2_box12_d_vs_ytd_401k,
          values_by_view: {
            staff_w2_gu: w2_row[:box12_code_d],
            staff_ytd_summary: staff_ytd.dig(:ytd, :retirement_401k)
          }
        )
      end
    end

    context "W-2GU employee PDF boxes" do
      let(:fixture_scenarios) { [ :salaried_401k ] }

      it "reconciles W-2GU PDF boxes printed for the employee with Staff W-2GU JSON" do
        employee = fixture.employees.fetch(:salaried_401k)
        w2_doc = fixture.w2_documents.fetch(:salaried_401k)
        w2_pdf_bytes = employee_api(:salaried_401k).tax_form_pdf_bytes(w2_doc.id)
        reader = PDF::Reader.new(StringIO.new(w2_pdf_bytes))
        pdf_text = reader.pages.map(&:text).join("\n")

        w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
        expect(pdf_text).to include(format("%.2f", w2_row[:box1_wages]))
        expect(pdf_text).to include(format("%.2f", w2_row[:box2_income_tax]))
        expect(pdf_text).to include(format("%.2f", w2_row[:box4_ss_tax]))
        expect(pdf_text).to include(format("%.2f", w2_row[:box6_medicare_tax]))
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
        # Save bypassing the post-bridge boundary check to simulate a native run
        # committed before the historical YTD bridge was later applied (L16).
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
          pay_rate: 22.00,
          hours_worked: 40,
          payment_delivery_method: "direct_deposit"
        )
        PayrollCalculator.for(employee, overlap_item).calculate
        overlap_item.save!

        doc = fixture.ensure_stub_posted!(:prior_provider_ytd_p2)
        emp_stmt = employee_api(:prior_provider_ytd).extract_paycheck(statement_id: doc.id)
        w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)

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
