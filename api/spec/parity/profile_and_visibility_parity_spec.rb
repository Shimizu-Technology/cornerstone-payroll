# frozen_string_literal: true

require_relative "parity_helper"

RSpec.describe "Profile, name suffix, voided check, reversal, contractor transition, and visibility parity", type: :request do
  include Parity::ParityContext
  include ActiveSupport::Testing::TimeHelpers

  describe "employee profile and contact parity across employee, client, and staff APIs" do
    it "matches contact info across employee, client, and staff APIs, and raw name fields between client and staff APIs" do
      %i[
        hourly_overtime
        salaried_401k
        additional_withholding_med
        prior_provider_ytd
        voided_check
        reversed_paycheck
        corrective_paycheck
        terminated_employee
        roth_401k
        native_non_taxable
        true_contractor
        same_period_bonus
      ].each do |key|
        employee = fixture.employees.fetch(key)
        emp_profile = employee_api(key).profile
        cli_profile = client_api.profile(employee.id)
        stf_profile = staff_api.profile(employee.id)

        assert_parity_table!(
          fixture: key,
          views: { employee_api: emp_profile, client_api: cli_profile, staff_api: stf_profile },
          figures: %i[email phone address_line1 address_line2 city state zip],
          allow_nil_figures: [ :address_line2 ]
        )

        # Raw name parts match between client and staff employee profile APIs without
        # synthesizing legal_name in the test extractor.
        assert_parity_table!(
          fixture: :"#{key}_raw_name",
          views: { client_api: cli_profile, staff_api: stf_profile },
          figures: %i[first_name middle_name last_name name_suffix],
          allow_nil_figures: %i[middle_name name_suffix]
        )
      end
    end

    context "name suffix parity (NEW-1)" do
      let(:fixture_scenarios) { [ :hourly_overtime ] }

      it "preserves name suffix ('Jr.', 'III') consistently across profile UI, payroll views, reports, W-2GU, and PDFs" do
      views = extract_all_paycheck_views(
        employee_key: :hourly_overtime,
        item_key: :hourly_overtime_p2,
        period: fixture.period2
      )
      employee = fixture.employees.fetch(:hourly_overtime)
      emp_profile = employee_api(:hourly_overtime).profile
      cli_profile = client_api.profile(employee.id)
      stf_profile = staff_api.profile(employee.id)
      staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      expect(staff_ytd).to be_present
      expect(w2_row).to be_present

      # Employee Profile, Employee PDF, Client PDF, and Check Stub PDF all use legal_name ("Mateo A Cruz Jr.").
      assert_parity!(
        fixture: :hourly_overtime,
        figure: :legal_name_on_documents,
        values_by_view: {
          employee_profile: emp_profile[:name],
          employee_stub_pdf: views.dig(:employee_stub_pdf, :employee_name),
          client_stub_pdf: views.dig(:client_stub_pdf, :employee_name),
          check_stub_pdf: views.dig(:check_stub_pdf, :employee_name)
        }
      )
      expect(emp_profile[:name]).to eq("Mateo A Cruz Jr.")

      # W-2GU JSON carries suffix either in employee_name or in its own suffix field
      # (matching Employee#legal_name comment at employee.rb:419-420).
      w2_name_or_suffix = if w2_row[:employee_name_suffix].present?
        "#{w2_row[:employee_name]} #{w2_row[:employee_name_suffix]}"
      else
        w2_row[:employee_name]
      end

      pending "NEW-1: ClientEmployeeOverview/EmployeeList show first+last ('Mateo Cruz') and pay period/history/YTD/W-2GU JSON use Employee#full_name (dropping 'Jr.') while employee profile and PDFs use Employee#legal_name"
      assert_parity!(
        fixture: :hourly_overtime,
        figure: :employee_name_with_suffix,
        values_by_view: {
          employee_profile: emp_profile[:name],
          client_profile_ui: cli_profile[:legal_name] || cli_profile[:ui_display_name],
          staff_profile_ui: stf_profile[:legal_name] || stf_profile[:ui_display_name],
          employee_stub_pdf: views.dig(:employee_stub_pdf, :employee_name),
          check_stub_pdf: views.dig(:check_stub_pdf, :employee_name),
          client_pay_period: views.dig(:client_pay_period, :employee_name),
          staff_pay_period: views.dig(:staff_pay_period, :employee_name),
          staff_pay_history: views.dig(:staff_pay_history, :employee_name),
          staff_ytd_summary: staff_ytd[:employee_name],
          staff_w2_gu: w2_name_or_suffix
        }
      )
      end
    end
  end

  describe "voided check visibility and status parity across multi-period history (L9 / D-10)" do
    let(:fixture_scenarios) { [ :voided_check ] }

    it "shows voided paper check status consistently across employee, client, and staff views while keeping both periods' wages in YTD" do
      employee = fixture.employees.fetch(:voided_check)
      item_p1 = fixture.items.fetch(:voided_check_p1)
      item_p2 = fixture.items.fetch(:voided_check_p2)
      doc_p1 = fixture.ensure_stub_posted!(:voided_check_p1)
      doc_p2 = fixture.documents.fetch(:voided_check_p2)

      # Period 1 (non-voided) is visible and agrees across all views.
      p1_views = extract_all_paycheck_views(employee_key: :voided_check, item_key: :voided_check_p1, period: fixture.period1)
      assert_parity!(
        fixture: :voided_check_p1,
        figure: :gross_pay,
        values_by_view: p1_views.transform_values { |v| dig_figure(v, :gross_pay) }
      )
      expect(doc_p1).to be_present

      # Period 2 (voided paper check): instrument void only; wages remain owed and in YTD.
      emp_view = employee_api(:voided_check).extract_paycheck(statement_id: doc_p2.id, list_year: Parity::FixtureBuilder::TAX_YEAR)
      cli_stubs = client_api.pay_stubs_index(employee.id).fetch("pay_stubs")
      cli_period = client_api.extract_pay_period_item(pay_period_id: fixture.period2.id, employee_id: employee.id)
      cli_history = client_api.extract_pay_history_item(
        employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR, payroll_item_id: item_p2.id
      )
      stf_period = staff_api.extract_pay_run_item(pay_period_id: fixture.period2.id, employee_id: employee.id)
      stf_history = staff_api.extract_pay_history_item(
        employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR, payroll_item_id: item_p2.id
      )
      voided_check_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item_p2).generate_voided)

      # Staff, Client pay history, and voided check PDF all agree on voided=true.
      assert_parity!(
        fixture: :voided_check_p2,
        figure: [ :status, :voided ],
        values_by_view: {
          staff_pay_period: stf_period.dig(:status, :voided),
          staff_pay_history: stf_history.dig(:status, :voided),
          client_pay_history: cli_history.dig(:status, :voided),
          check_stub_pdf: voided_check_pdf.dig(:status, :voided)
        }
      )
      expect(stf_period.dig(:status, :voided)).to eq(true)
      expect(cli_stubs.any? { |s| s["id"].to_i == item_p2.id }).to eq(true)
      expect(cli_period.dig(:status, :visible)).to eq(true)

      # Both Period 1 AND Period 2 wages remain counted in YTD summary (instrument void != reversal).
      staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      client_ytd = client_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      expected_two_period_gross = (item_p1.gross_pay.to_d + item_p2.gross_pay.to_d).round(2)
      assert_parity!(
        fixture: :voided_check_ytd,
        figure: [ :ytd, :gross ],
        values_by_view: {
          expected_sum: expected_two_period_gross,
          client_ytd_summary: client_ytd.dig(:ytd, :gross),
          staff_ytd_summary: staff_ytd.dig(:ytd, :gross)
        }
      )

      assert_parity!(
        fixture: :voided_check_p2,
        figure: [ :status, :visible ],
        values_by_view: {
          employee_api: emp_view.dig(:status, :visible),
          client_pay_stubs: cli_stubs.any? { |s| s["id"].to_i == item_p2.id },
          client_pay_period: cli_period.dig(:status, :visible),
          staff_pay_period: stf_period.dig(:status, :visible)
        }
      )
    end
  end

  describe "reversed paycheck exclusion and multi-period YTD parity (ReversePaycheckService)" do
    let(:fixture_scenarios) { [ :reversed_paycheck ] }

    it "removes a reversed Period 2 paycheck from pay and YTD across employee, client, staff, and W-2GU while keeping Period 1 intact" do
      employee = fixture.employees.fetch(:reversed_paycheck)
      item_p1 = fixture.items.fetch(:reversed_paycheck_p1)
      item_p2 = fixture.items.fetch(:reversed_paycheck_p2)
      doc_p1 = fixture.ensure_stub_posted!(:reversed_paycheck_p1)
      doc_p2 = fixture.documents.fetch(:reversed_paycheck_p2)

      # Period 1 stands and matches across all views.
      p1_views = extract_all_paycheck_views(employee_key: :reversed_paycheck, item_key: :reversed_paycheck_p1, period: fixture.period1)
      assert_parity_table!(
        fixture: :reversed_paycheck_p1,
        views: p1_views,
        figures: [ :gross_pay, :net_pay, [ :taxes, :total_taxes ] ]
      )

      # Period 2 was reversed: a notice in employee statements, excluded from client pay period, client pay stubs,
      # client/staff pay history, and marked payroll_included: false on staff pay run.
      emp_p2 = employee_api(:reversed_paycheck).extract_paycheck(statement_id: doc_p2.id, list_year: Parity::FixtureBuilder::TAX_YEAR)
      cli_p2 = client_api.extract_pay_period_item(pay_period_id: fixture.period2.id, employee_id: employee.id)
      cli_stubs = client_api.pay_stubs_index(employee.id).fetch("pay_stubs")
      stf_p2 = staff_api.extract_pay_run_item(pay_period_id: fixture.period2.id, employee_id: employee.id)

      expect(emp_p2.dig(:status, :visible)).to eq(true)
      expect(emp_p2[:net_pay]).to be_nil
      expect(cli_p2.dig(:status, :visible)).to eq(false)
      expect(cli_stubs.any? { |s| s["id"].to_i == item_p2.id }).to eq(false)
      expect(stf_p2.dig(:status, :payroll_included)).to eq(false)

      # YTD across employee statement (P1), client YTD summary, staff YTD summary, and W-2GU
      # reflects ONLY Period 1 (Period 2 is completely removed).
      emp_p1 = employee_api(:reversed_paycheck).extract_paycheck(statement_id: doc_p1.id)
      cli_ytd = client_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      stf_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)

      expect(cli_ytd).to be_present
      expect(stf_ytd).to be_present
      expect(w2_row).to be_present

      assert_parity_table!(
        fixture: :reversed_paycheck_ytd,
        views: {
          employee_api: emp_p1,
          client_ytd_summary: cli_ytd,
          staff_ytd_summary: stf_ytd
        },
        figures: [
          [ :ytd, :gross ],
          [ :ytd, :total_income_tax ],
          [ :ytd, :social_security ],
          [ :ytd, :medicare_total ],
          [ :ytd, :net ]
        ]
      )
      expect(stf_ytd.dig(:ytd, :gross)).to eq(item_p1.gross_pay.to_d.round(2))
      expect(w2_row[:box2_income_tax]).to eq(emp_p1.dig(:ytd, :total_income_tax))
    end
  end

  describe "contractor classification change on multi-period historical paychecks (L6)" do
    let(:fixture_scenarios) { [ :contractor_transition ] }

    it "prints historical W-2 taxes on check stub PDFs matching pay stub PDFs across both periods even after employee becomes a contractor" do
      %i[contractor_transition_p1 contractor_transition_p2].each do |item_key|
        item = fixture.items.fetch(item_key)
        doc = fixture.ensure_stub_posted!(item_key)

        emp_pdf = pay_stub_pdf_extractor.extract(employee_api(:contractor_transition).statement_pdf_bytes(doc.id))
        chk_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item).generate)

        # PayStubGenerator correctly checks payroll_item.contractor? (false), so taxes are printed.
        expect(emp_pdf.dig(:taxes, :total_taxes)).to be > 0
      end

      item_p2 = fixture.items.fetch(:contractor_transition_p2)
      doc_p2 = fixture.ensure_stub_posted!(:contractor_transition_p2)
      emp_pdf = pay_stub_pdf_extractor.extract(employee_api(:contractor_transition).statement_pdf_bytes(doc_p2.id))
      chk_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item_p2).generate)

      pending "L6: CheckGenerator#tax_rows checks employee.contractor? (current status) instead of payroll_item.contractor?, dropping all taxes on historical W-2 check stubs"
      assert_parity_table!(
        fixture: :contractor_transition_p2,
        views: {
          employee_stub_pdf: emp_pdf,
          check_stub_pdf: chk_pdf
        },
        figures: [ [ :taxes, :total_taxes ] ]
      )
      assert_parity!(
        fixture: :contractor_transition_p2,
        figure: [ :taxes, :printed_total_vs_pay_stub ],
        values_by_view: {
          employee_stub_pdf: emp_pdf.dig(:taxes, :total_taxes),
          check_stub_printed_total: chk_pdf.dig(:taxes, :printed_total)
        }
      )
    end
  end

  describe "pay-date posting cutoff visibility window at 05:59 vs 06:00 Guam time (L10 — documented intentional behavior)" do
    let(:fixture_scenarios) { [ :hourly_overtime ] }
    let(:include_future_period) { true }

    it "holds employee stub posting at 05:59 Guam time on pay_date and posts it at 06:00 Guam time matching client and staff" do
      guam_zone = Time.find_zone!(PayStubGenerator::GUAM_TIME_ZONE)
      pay_date = Parity::FixtureBuilder::FUTURE_PERIOD_PAY
      employee = fixture.employees.fetch(:hourly_overtime)
      future_item = fixture.items.fetch(:hourly_overtime_future)

      # At 05:59:59 Guam time on pay_date: client/staff see it, employee API holds it.
      travel_to(guam_zone.local(pay_date.year, pay_date.month, pay_date.day, 5, 59, 59)) do
        expect(fixture.ensure_stub_posted!(:hourly_overtime_future, now: Time.current)).to be_nil

        emp_statements = employee_api(:hourly_overtime).statements_list(year: Parity::FixtureBuilder::TAX_YEAR).fetch("statements")
        emp_sees_future = emp_statements.any? { |s| s.dig("pay_period", "pay_date") == pay_date.iso8601 }
        cli_period = client_api.extract_pay_period_item(pay_period_id: fixture.future_period.id, employee_id: employee.id)
        cli_stubs = client_api.pay_stubs_index(employee.id).fetch("pay_stubs")
        stf_period = staff_api.extract_pay_run_item(pay_period_id: fixture.future_period.id, employee_id: employee.id)

        expect(emp_sees_future).to eq(false)
        expect(cli_period.dig(:status, :visible)).to eq(true)
        expect(cli_stubs.any? { |s| s["id"].to_i == future_item.id }).to eq(true)
        expect(stf_period.dig(:status, :visible)).to eq(true)
      end

      # At 06:00:00 Guam time on pay_date: stub posts and matches client/staff to the cent.
      travel_to(guam_zone.local(pay_date.year, pay_date.month, pay_date.day, 6, 0, 0)) do
        posted_doc = fixture.ensure_stub_posted!(:hourly_overtime_future, now: Time.current)
        expect(posted_doc).to be_present

        emp_view = employee_api(:hourly_overtime).extract_paycheck(statement_id: posted_doc.id, list_year: Parity::FixtureBuilder::TAX_YEAR)
        cli_period = client_api.extract_pay_period_item(pay_period_id: fixture.future_period.id, employee_id: employee.id)
        stf_period = staff_api.extract_pay_run_item(pay_period_id: fixture.future_period.id, employee_id: employee.id)

        expect(emp_view.dig(:status, :visible)).to eq(true)
        assert_parity_table!(
          fixture: :hourly_overtime_future_0600,
          views: { employee_api: emp_view, client_pay_period: cli_period, staff_pay_period: stf_period },
          figures: [ :gross_pay, :net_pay, [ :taxes, :total_taxes ], [ :dates, :pay_date ] ]
        )
      end
    end
  end
end
