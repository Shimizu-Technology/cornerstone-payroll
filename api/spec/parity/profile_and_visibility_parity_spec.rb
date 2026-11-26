# frozen_string_literal: true

require_relative "parity_helper"

RSpec.describe "Profile, name suffix, voided check, contractor transition, and visibility parity", type: :request do
  include Parity::ParityContext

  describe "employee profile and contact parity across employee, client, and staff APIs" do
    it "matches name (with suffix), email, phone, and address across every fixture employee in employee, client, and staff profile APIs" do
      %i[
        hourly_overtime
        salaried_401k
        additional_withholding_med
        prior_provider_ytd
        voided_check
        corrective_paycheck
        terminated_employee
      ].each do |key|
        employee = fixture.employees.fetch(key)
        profiles = {
          employee_api: employee_api(key).profile,
          client_api: client_api.profile(employee.id),
          staff_api: staff_api.profile(employee.id)
        }

        %i[name email phone address_line1 address_line2 city state zip].each do |field|
          assert_parity!(
            fixture: key,
            figure: field,
            values_by_view: profiles.transform_values { |p| p[field] }
          )
        end
      end
    end

    it "preserves name suffix ('Jr.', 'III') consistently across payroll views, reports, W-2GU, and PDFs" do
      views = extract_all_paycheck_views(
        employee_key: :hourly_overtime,
        item_key: :hourly_overtime_p2,
        period: fixture.period2
      )
      employee = fixture.employees.fetch(:hourly_overtime)
      emp_profile = employee_api(:hourly_overtime).profile
      staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      w2_row = staff_api.extract_w2_employee_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)

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

      pending "NEW-1: Client/Staff pay period, pay history, YTD summary, and W-2GU JSON use Employee#full_name (dropping name_suffix 'Jr.') while employee profile and PDFs use Employee#legal_name"
      assert_parity!(
        fixture: :hourly_overtime,
        figure: :employee_name_with_suffix,
        values_by_view: {
          employee_profile: emp_profile[:name],
          employee_stub_pdf: views.dig(:employee_stub_pdf, :employee_name),
          check_stub_pdf: views.dig(:check_stub_pdf, :employee_name),
          client_pay_period: views.dig(:client_pay_period, :employee_name),
          staff_pay_period: views.dig(:staff_pay_period, :employee_name),
          staff_pay_history: views.dig(:staff_pay_history, :employee_name),
          staff_ytd_summary: staff_ytd[:employee_name],
          staff_w2_gu: w2_row[:employee_name]
        }
      )
    end
  end

  describe "voided check visibility and status parity (L9 / D-10)" do
    let(:fixture_scenarios) { [ :voided_check ] }

    it "shows voided paper check status consistently across employee, client, and staff views while keeping wages in YTD" do
      employee = fixture.employees.fetch(:voided_check)
      item = fixture.items.fetch(:voided_check_p1)
      doc = fixture.documents.fetch(:voided_check_p1)

      emp_view = employee_api(:voided_check).extract_paycheck(statement_id: doc.id, list_year: Parity::FixtureBuilder::TAX_YEAR)
      cli_stubs = client_api.pay_stubs_index(employee.id).fetch("pay_stubs")
      cli_period = client_api.extract_pay_period_item(pay_period_id: fixture.period1.id, employee_id: employee.id)
      cli_history = client_api.extract_pay_history_item(
        employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR, payroll_item_id: item.id
      )
      stf_period = staff_api.extract_pay_run_item(pay_period_id: fixture.period1.id, employee_id: employee.id)
      stf_history = staff_api.extract_pay_history_item(
        employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR, payroll_item_id: item.id
      )
      voided_check_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item).generate_voided)

      # Staff, Client pay history, and voided check PDF all agree on voided=true and full figures.
      assert_parity!(
        fixture: :voided_check,
        figure: [ :status, :voided ],
        values_by_view: {
          staff_pay_period: stf_period.dig(:status, :voided),
          staff_pay_history: stf_history.dig(:status, :voided),
          client_pay_history: cli_history.dig(:status, :voided),
          check_stub_pdf: voided_check_pdf.dig(:status, :voided)
        }
      )
      expect(stf_period.dig(:status, :voided)).to eq(true)
      expect(cli_stubs.any? { |s| s["id"].to_i == item.id }).to eq(true)
      expect(cli_period.dig(:status, :visible)).to eq(true)

      # Wages remain counted in YTD summary (instrument void only, not financial reversal).
      staff_ytd = staff_api.extract_ytd_summary_row(employee_id: employee.id, year: Parity::FixtureBuilder::TAX_YEAR)
      expect(staff_ytd.dig(:ytd, :gross)).to eq(stf_period[:gross_pay])

      pending "L9: voided paper checks (wages still owed) are hidden from Employee Statements API while still listed in Client Pay Stubs, Client Pay Period, and Staff views"
      assert_parity!(
        fixture: :voided_check,
        figure: [ :status, :visible ],
        values_by_view: {
          employee_api: emp_view.dig(:status, :visible),
          client_pay_stubs: cli_stubs.any? { |s| s["id"].to_i == item.id },
          client_pay_period: cli_period.dig(:status, :visible),
          staff_pay_period: stf_period.dig(:status, :visible)
        }
      )
    end
  end

  describe "contractor classification change on historical paycheck (L6)" do
    let(:fixture_scenarios) { [ :contractor_transition ] }

    it "prints historical W-2 taxes on the check stub PDF matching the pay stub PDF even after employee becomes a contractor" do
      item = fixture.items.fetch(:contractor_transition_p1)
      doc = fixture.ensure_stub_posted!(:contractor_transition_p1)

      emp_pdf = pay_stub_pdf_extractor.extract(employee_api(:contractor_transition).statement_pdf_bytes(doc.id))
      chk_pdf = check_stub_pdf_extractor.extract(CheckGenerator.new(item).generate)

      # PayStubGenerator correctly checks payroll_item.contractor? (false), so taxes are printed.
      expect(emp_pdf.dig(:taxes, :total_taxes)).to be > 0

      pending "L6: CheckGenerator#tax_rows checks employee.contractor? (current status) instead of payroll_item.contractor?, dropping all taxes on historical W-2 check stubs"
      assert_parity!(
        fixture: :contractor_transition,
        figure: [ :taxes, :total_taxes ],
        values_by_view: {
          employee_stub_pdf: emp_pdf.dig(:taxes, :total_taxes),
          check_stub_pdf: chk_pdf.dig(:taxes, :total_taxes)
        }
      )
    end
  end

  describe "pay-date posting cutoff visibility window (L10 — documented intentional behavior)" do
    let(:fixture_scenarios) { [ :hourly_overtime ] }
    let(:include_future_period) { true }

    it "makes a future-dated committed run visible to client/staff immediately while holding employee stub posting until 6:00 AM Guam time on pay_date" do
      employee = fixture.employees.fetch(:hourly_overtime)
      future_item = fixture.items.fetch(:hourly_overtime_future)

      # PostPayStub ran at POSTING_NOW (Feb 25) while future_period pay_date is Mar 20 -> not posted.
      expect(fixture.ensure_stub_posted!(:hourly_overtime_future)).to be_nil

      emp_statements = employee_api(:hourly_overtime).statements_list(year: Parity::FixtureBuilder::TAX_YEAR).fetch("statements")
      emp_sees_future = emp_statements.any? { |s| s.dig("pay_period", "pay_date") == Parity::FixtureBuilder::FUTURE_PERIOD_PAY.iso8601 }

      cli_period = client_api.extract_pay_period_item(pay_period_id: fixture.future_period.id, employee_id: employee.id)
      cli_stubs = client_api.pay_stubs_index(employee.id).fetch("pay_stubs")
      stf_period = staff_api.extract_pay_run_item(pay_period_id: fixture.future_period.id, employee_id: employee.id)

      # L10 documented rule (PLAN.md §13): intentional posting-window difference.
      expect(emp_sees_future).to eq(false)
      expect(cli_period.dig(:status, :visible)).to eq(true)
      expect(cli_stubs.any? { |s| s["id"].to_i == future_item.id }).to eq(true)
      expect(stf_period.dig(:status, :visible)).to eq(true)
    end
  end
end
