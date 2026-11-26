# frozen_string_literal: true

require "rails_helper"
require "csv"
require "pdf/reader"
require "roo"

RSpec.describe "Api::V1::Client::Reports", type: :request do
  let!(:company) { create(:company, name: "Reports Co") }
  let!(:department) { create(:department, company: company) }
  let!(:client_user) { create(:user, company: company, role: "client", email: "reports-client@example.com") }
  let!(:employee) { create(:employee, company: company, department: department, first_name: "Ana", last_name: "Perez") }
  let!(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 18))
  end
  let!(:draft_pay_period) do
    create(:pay_period,
      company: company,
      start_date: Date.new(2026, 4, 15),
      end_date: Date.new(2026, 4, 28),
      pay_date: Date.new(2026, 5, 2),
      status: "draft")
  end

  let!(:payroll_item) do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      gross_pay: 1450.0,
      net_pay: 1170.0,
      withholding_tax: 120.0,
      social_security_tax: 89.9,
      employer_social_security_tax: 89.9,
      medicare_tax: 20.3,
      employer_medicare_tax: 20.3,
      total_deductions: 280.0,
      custom_earnings: [ { "label" => "Certification Pay", "amount" => 50.0 } ],
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 30.0 } ])
  end

  let!(:payroll_field_definition) do
    PayrollFieldDefinition.create!(
      company: company,
      name: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent"
    )
  end

  let!(:payroll_field_entry) do
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: payroll_field_definition,
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 75.0,
      source: "manual"
    )
  end

  before do
    CompanyAssignment.create!(user: client_user, company: company)

    create(:payroll_item,
      pay_period: draft_pay_period,
      employee: employee,
      company: company,
      gross_pay: 9999.0,
      net_pay: 8000.0,
      withholding_tax: 800.0,
      social_security_tax: 619.94,
      employer_social_security_tax: 619.94,
      medicare_tax: 144.99,
      employer_medicare_tax: 144.99)

    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(company.id)
  end

  it "returns raw calendar dates for the dashboard's recent pay periods" do
    get "/api/v1/client/reports/dashboard"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("stats", "recent_payrolls").sole).to include(
      "id" => pay_period.id, "start_date" => "2026-04-01", "end_date" => "2026-04-14", "pay_date" => "2026-04-18"
    )
  end

  it "logs ambiguous YTD details and sends a client-safe message" do
    error = PayrollComponentMirrors::AmbiguousHistoryError.new("Staff-only history repair instructions")
    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:build_period_summary_report).and_raise(error)
    expect(Rails.error).to receive(:report).with(error, handled: true, context: {
      company_id: company.id, action: "ytd_summary"
    }).and_call_original

    get "/api/v1/client/reports/ytd_summary", params: { year: 2026 }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq("error" => "Payroll details are unavailable right now. Contact Cornerstone.")
  end

  describe "expanded client report boundary" do
    let(:report_params) { { pay_period_id: pay_period.id, employee_id: employee.id, year: 2026, quarter: 2 } }

    it "keeps staff Form 500 tracking details out of client packets and exports" do
      Form500Filing.create!(company: company, pay_period: pay_period, fields: { "test" => true },
        notes: "Private staff tracking note", confirmation_number: "STAFF-123", receipt_attached: true,
        payment_date: Date.new(2026, 4, 20), payment_amount: 120)
      get "/api/v1/client/reports/quarterly_compliance_packet", params: report_params
      expect(response).to have_http_status(:ok)
      deposit = response.parsed_body.dig("report", "form_500", "deposits").sole
      expect(deposit).to include("amount" => 120.0, "payment_date" => "2026-04-20")
      expect(deposit.keys & %w[notes confirmation_number receipt_attached]).to be_empty
      report = response.parsed_body.fetch("report")
      expect(%w[federal_941 w1 swica].map { |section| report.dig(section, "filing_steps") }).to all(be_nil)
      expect(report).not_to have_key("review_checks")
      expect(%w[w1 swica].map { |section| report.fetch(section).key?("tie_out") }).to all(be(false))
      %w[quarterly_compliance_packet_pdf quarterly_compliance_packet_xlsx].each do |action|
        get "/api/v1/client/reports/#{action}", params: report_params
        expect(response).to have_http_status(:ok)
        text = if action.end_with?("pdf")
          PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")
        else
          sheet = Roo::Excelx.new(StringIO.new(response.body))
          sheet.sheets.flat_map { |name| sheet.sheet(name).to_a.flatten }.join(" ")
        end
        expect(text).not_to include("Private staff tracking note", "STAFF-123")
      end
      staff = QuarterlyCompliancePacketBuilder.new(company, 2026, 2).generate
      expect(staff.dig(:form_500, :deposits).sole).to include(notes: "Private staff tracking note", confirmation_number: "STAFF-123", receipt_attached: true)
      expect(%i[federal_941 w1 swica].map { |section| staff.dig(section, :filing_steps) }).to all(be_present)
      expect(staff[:review_checks]).to be_present
      expect(%i[w1 swica].map { |section| staff.dig(section, :tie_out) }).to all(be_present)
    end

    it "keeps voided and reversed checks in the client Checks and Payments Register" do
      payroll_item.update_columns(voided: true)
      reversed = create(:payroll_item, company: company, employee: create(:employee, company: company), pay_period: pay_period, gross_pay: 50, net_pay: 40)
      reversed.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: client_user.id, payroll_reversal_reason: "Synthetic reversal")
      get "/api/v1/client/reports/paycheck_history_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")
      expect(text.scan(/voided/i).size).to be >= 2
    end

    it "hides staff component review warnings in client JSON and PDFs while preserving staff defaults" do
      warning = { code: PayrollReportComponentReview::CODE, message: PayrollReportComponentReview::MESSAGE }
      allow(PayrollReportComponentReview).to receive(:for_items).and_return([ warning ])
      %w[ytd_summary employee_pay_history].each do |action|
        get "/api/v1/client/reports/#{action}", params: report_params.merge(start_date: "2026-01-01", end_date: "2026-12-31")
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(warning[:message])
      end
      %w[payroll_summary_by_employee_pdf paycheck_history_pdf deductions_contributions_pdf retirement_plans_pdf payroll_register_pdf].each do |action|
        get "/api/v1/client/reports/#{action}", params: report_params
        expect(response).to have_http_status(:ok)
        text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")
        expect(text).not_to include("accountant review needed")
      end
      expect(QuickbooksPayrollReportData.new(pay_period).review_warnings).to eq([ warning ])
      text = PDF::Reader.new(StringIO.new(PayrollSummaryByEmployeePdfGenerator.new(pay_period).generate)).pages.map(&:text).join(" ")
      expect(text).to include("accountant review needed")
    end

    it "serves payroll_summary_by_employee_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/payroll_summary_by_employee_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/payroll_summary_by_employee_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves payroll_summary_by_employee_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/payroll_summary_by_employee_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/payroll_summary_by_employee_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves tax_summary for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/tax_summary", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/tax_summary", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves tax_summary_csv for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/tax_summary_csv", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/tax_summary_csv", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves tax_summary_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/tax_summary_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/tax_summary_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves tax_summary_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/tax_summary_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/tax_summary_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employer_liability for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employer_liability", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employer_liability", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employer_liability_csv for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employer_liability_csv", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employer_liability_csv", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employer_liability_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employer_liability_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employer_liability_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employer_liability_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employer_liability_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employer_liability_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves form_941_gu for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/form_941_gu", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/form_941_gu", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves form_941_gu_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/form_941_gu_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/form_941_gu_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves form_941_gu_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/form_941_gu_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/form_941_gu_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves quarterly_compliance_packet for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/quarterly_compliance_packet", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/quarterly_compliance_packet", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves quarterly_compliance_packet_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/quarterly_compliance_packet_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/quarterly_compliance_packet_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves quarterly_compliance_packet_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/quarterly_compliance_packet_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/quarterly_compliance_packet_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves quarterly_compliance_packet_form_941_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/quarterly_compliance_packet_form_941_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/quarterly_compliance_packet_form_941_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves quarterly_compliance_packet_schedule_b_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/quarterly_compliance_packet_schedule_b_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/quarterly_compliance_packet_schedule_b_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves quarterly_compliance_packet_w1_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/quarterly_compliance_packet_w1_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/quarterly_compliance_packet_w1_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves quarterly_compliance_packet_swica_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/quarterly_compliance_packet_swica_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/quarterly_compliance_packet_swica_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employee_pay_history for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employee_pay_history", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employee_pay_history", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employee_pay_history_csv for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employee_pay_history_csv", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employee_pay_history_csv", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employee_pay_history_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employee_pay_history_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employee_pay_history_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves employee_pay_history_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/employee_pay_history_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/employee_pay_history_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves paycheck_history_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/paycheck_history_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/paycheck_history_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves paycheck_history_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/paycheck_history_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/paycheck_history_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves deductions_contributions_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/deductions_contributions_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/deductions_contributions_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves deductions_contributions_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/deductions_contributions_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/deductions_contributions_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves retirement_plans_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/retirement_plans_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/retirement_plans_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves retirement_plans_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/retirement_plans_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/retirement_plans_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves installment_loans_pdf for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/installment_loans_pdf", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/installment_loans_pdf", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "serves installment_loans_xlsx for the current company and rejects a foreign company context" do
      get "/api/v1/client/reports/installment_loans_xlsx", params: report_params
      expect(response).to have_http_status(:ok)
      other = create(:company)
      allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/client/reports/installment_loans_xlsx", params: report_params
      expect(response.status).to be_in([ 403, 404 ])
    end

    it "refuses unfinished payroll for payroll_summary_by_employee_pdf" do
      get "/api/v1/client/reports/payroll_summary_by_employee_pdf", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses unfinished payroll for payroll_summary_by_employee_xlsx" do
      get "/api/v1/client/reports/payroll_summary_by_employee_xlsx", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses unfinished payroll for paycheck_history_pdf" do
      get "/api/v1/client/reports/paycheck_history_pdf", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses unfinished payroll for paycheck_history_xlsx" do
      get "/api/v1/client/reports/paycheck_history_xlsx", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses unfinished payroll for deductions_contributions_pdf" do
      get "/api/v1/client/reports/deductions_contributions_pdf", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses unfinished payroll for deductions_contributions_xlsx" do
      get "/api/v1/client/reports/deductions_contributions_xlsx", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses unfinished payroll for retirement_plans_pdf" do
      get "/api/v1/client/reports/retirement_plans_pdf", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses unfinished payroll for retirement_plans_xlsx" do
      get "/api/v1/client/reports/retirement_plans_xlsx", params: report_params.merge(pay_period_id: draft_pay_period.id)
      expect(response).to have_http_status(:not_found)
    end

    context "in a practice copy" do
      before do
        source = create(:company, organization: company.organization)
        source_period = create(:pay_period, :committed, company: source)
        company.update!(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
          migration_source_company: source, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
        client_user.update!(practice_company_id: company.id)
        pay_period.update_columns(status: "approved", test_workspace_role: "baseline", test_workspace_source_pay_period_id: source_period.id)
        # A run created inside the copy, like the Oct 19–Nov 1 rehearsal period: approved but never finished.
        draft_pay_period.update_columns(status: "approved")
      end

      it "serves copied baseline history for payroll_summary_by_employee_pdf" do
        get "/api/v1/client/reports/payroll_summary_by_employee_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for payroll_summary_by_employee_xlsx" do
        get "/api/v1/client/reports/payroll_summary_by_employee_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for tax_summary" do
        get "/api/v1/client/reports/tax_summary", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for tax_summary_csv" do
        get "/api/v1/client/reports/tax_summary_csv", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for tax_summary_pdf" do
        get "/api/v1/client/reports/tax_summary_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for tax_summary_xlsx" do
        get "/api/v1/client/reports/tax_summary_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employer_liability" do
        get "/api/v1/client/reports/employer_liability", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employer_liability_csv" do
        get "/api/v1/client/reports/employer_liability_csv", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employer_liability_pdf" do
        get "/api/v1/client/reports/employer_liability_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employer_liability_xlsx" do
        get "/api/v1/client/reports/employer_liability_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for form_941_gu" do
        get "/api/v1/client/reports/form_941_gu", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for form_941_gu_pdf" do
        get "/api/v1/client/reports/form_941_gu_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for form_941_gu_xlsx" do
        get "/api/v1/client/reports/form_941_gu_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for quarterly_compliance_packet" do
        get "/api/v1/client/reports/quarterly_compliance_packet", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for quarterly_compliance_packet_pdf" do
        get "/api/v1/client/reports/quarterly_compliance_packet_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for quarterly_compliance_packet_xlsx" do
        get "/api/v1/client/reports/quarterly_compliance_packet_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for quarterly_compliance_packet_form_941_pdf" do
        get "/api/v1/client/reports/quarterly_compliance_packet_form_941_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for quarterly_compliance_packet_schedule_b_pdf" do
        get "/api/v1/client/reports/quarterly_compliance_packet_schedule_b_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for quarterly_compliance_packet_w1_pdf" do
        get "/api/v1/client/reports/quarterly_compliance_packet_w1_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for quarterly_compliance_packet_swica_pdf" do
        get "/api/v1/client/reports/quarterly_compliance_packet_swica_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employee_pay_history" do
        get "/api/v1/client/reports/employee_pay_history", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employee_pay_history_csv" do
        get "/api/v1/client/reports/employee_pay_history_csv", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employee_pay_history_pdf" do
        get "/api/v1/client/reports/employee_pay_history_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for employee_pay_history_xlsx" do
        get "/api/v1/client/reports/employee_pay_history_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for paycheck_history_pdf" do
        get "/api/v1/client/reports/paycheck_history_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for paycheck_history_xlsx" do
        get "/api/v1/client/reports/paycheck_history_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for deductions_contributions_pdf" do
        get "/api/v1/client/reports/deductions_contributions_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for deductions_contributions_xlsx" do
        get "/api/v1/client/reports/deductions_contributions_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for retirement_plans_pdf" do
        get "/api/v1/client/reports/retirement_plans_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for retirement_plans_xlsx" do
        get "/api/v1/client/reports/retirement_plans_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for installment_loans_pdf" do
        get "/api/v1/client/reports/installment_loans_pdf", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "serves copied baseline history for installment_loans_xlsx" do
        get "/api/v1/client/reports/installment_loans_xlsx", params: report_params
        expect(response).to have_http_status(:ok)
      end

      it "includes baselines and excludes approved practice drafts in annual and period totals" do
        %w[ytd_summary tax_summary annual_payroll_summary].each do |action|
          get "/api/v1/client/reports/#{action}", params: report_params
          expect(response).to have_http_status(:ok)
          report = response.parsed_body.fetch("report")
          gross = report.dig("company_totals", "gross_pay") || report.dig("totals", "gross_wages") || report.dig("totals", "gross_pay")
          expect(gross.to_f).to eq(1450)
        end
      end
    end

    it "uses only finished payroll for tax and annual totals" do
      get "/api/v1/client/reports/tax_summary", params: report_params
      expect(response.parsed_body.dig("report", "totals", "gross_wages").to_f).to eq(1450)
      get "/api/v1/client/reports/annual_payroll_summary"
      expect(response.parsed_body.dig("report", "totals", "gross_pay").to_f).to eq(1450)
    end
  end

  def create_client_historical_paycheck(employee:, suffix:, gross_pay: 400, net_pay: 290)
    batch = HistoricalImportBatch.create!(
      company: company,
      source_label: "QuickBooks #{suffix}",
      bundle_digest: "client-reports-#{company.id}-#{suffix}",
      importer_version: "quickbooks-online-payroll-v5",
      status: "locked",
      locked_at: Time.zone.parse("2026-03-25 09:00"),
      locked_by: client_user
    )
    period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "period-#{suffix}",
      source_label: "Payroll #{suffix}",
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14),
      pay_date: Date.new(2026, 3, 20),
      paycheck_count: 1,
      totals: { "gross_pay" => gross_pay.to_s, "net_pay" => net_pay.to_s }
    )
    worker = HistoricalWorker.create!(
      historical_import_batch: batch,
      company: company,
      employee: employee,
      external_key: "worker-#{suffix}",
      source_name: employee&.full_name || "Unlinked Worker",
      normalized_name: employee&.full_name&.downcase || "unlinked worker",
      source_status: "active",
      mapping_status: employee ? "exact_match" : "archive_only"
    )
    HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "check-#{suffix}",
      source_employee_name: employee&.full_name || "Unlinked Worker",
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: employee ? "matched" : "unmatched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      gross_pay: gross_pay,
      adjusted_gross: gross_pay,
      employee_taxes: 80,
      federal_income_tax: 50,
      social_security_tax: 25,
      medicare_tax: 5,
      after_tax_deductions: 30,
      net_pay: net_pay
    )
  end

  it "exposes the dashboard and read-only payroll register to client users" do
    get "/api/v1/client/reports/dashboard"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("stats", "ytd_totals", "gross_pay").to_f).to eq(1450.0)

    get "/api/v1/client/reports/payroll_register", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("report", "summary", "employee_count")).to eq(1)
    expect(response.parsed_body.dig("report", "summary", "total_custom_earnings").to_f).to eq(50.0)
    expect(response.parsed_body.dig("report", "summary", "total_custom_deductions").to_f).to eq(30.0)
    expect(response.parsed_body.dig("report", "summary", "total_payroll_field_post_tax_deductions").to_f).to eq(75.0)
    employee_row = response.parsed_body.dig("report", "employees", 0)
    expect(employee_row).not_to have_key("check_number")
    expect(employee_row.dig("payroll_field_entries", 0, "label")).to eq("Rent Deduction")
    expect(employee_row.dig("payroll_field_entries", 0, "amount").to_f).to eq(75.0)

    get "/api/v1/client/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to include("application/pdf")
    expect(response.body).to start_with("%PDF")
  end

  it "preserves check numbers and adjustment notes in the client history and deductions workbooks" do
    payroll_item.update!(check_number: "TEST-100", payroll_adjustments: [
      { "label" => "Shift premium", "treatment" => "taxable_addition", "amount" => 10, "notes" => "Shift premium test memo" }
    ])

    { "paycheck_history" => "Payroll Register Rows", "deductions_contributions" => "Payroll Rows" }.each do |action, sheet|
      get "/api/v1/client/reports/#{action}_xlsx", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      workbook = Roo::Excelx.new(StringIO.new(response.body))
      rows = workbook.sheet(sheet).to_a
      header = rows.index { |row| row.include?("Check Number") }
      expect(rows.fetch(header + 1).fetch(rows.fetch(header).index("Check Number"))).to eq("TEST-100")
      rows = workbook.sheet("Payroll Adjustments Detail").to_a
      header = rows.index { |row| row.include?("Notes") }
      expect(rows.fetch(header + 1).fetch(rows.fetch(header).index("Notes"))).to eq("Shift premium test memo")
    end
  end

  it "reconciles client payroll register totals and preserves its row visibility" do
    payroll_item.update!(hours_worked: 70.25, overtime_hours: 4.5, bonus: 42.67,
      reported_tips: 20, tips_paid_out: 10, additional_withholding: 12.34, check_number: "TEST-100",
      additional_withholding_override: 12.34, loan_deduction: 10, loan_payment: 25, employer_retirement_match: 24,
      payroll_adjustments: [
        { "label" => "Shift premium", "treatment" => "taxable_addition", "amount" => 10, "notes" => "Internal test memo" }
      ])
    params = { pay_period_id: pay_period.id }
    get "/api/v1/client/reports/payroll_register", params: params

    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    summary = report.fetch("summary")
    expect(summary.transform_values(&:to_d)).to include(
      "total_hours" => 70.25.to_d, "total_overtime_hours" => 4.5.to_d,
      "total_bonus" => 42.67.to_d, "total_reported_tips" => 20.to_d, "total_tips_paid_out" => 10.to_d,
      "total_straight_loan_deductions" => 10.to_d, "total_installment_loan_payments" => 15.to_d,
      "total_employer_contributions" => 24.to_d, "total_employer_payroll_cost" => 1584.2.to_d
    )
    expect(report.keys).to match_array(%w[type meta source pay_period summary employees contractors register_review])
    expect(report.fetch("meta").keys).to match_array(%w[company_name generated_at])
    expect(report.dig("meta", "company_name")).to eq(company.name)
    expect(report.dig("source", "system")).to eq("cornerstone")
    row = report.fetch("employees").sole
    expect(summary.fetch("total_employer_payroll_cost").to_d).to eq(row.fetch("employer_payroll_cost").to_d)
    expect(summary.fetch("total_employer_contributions").to_d).to eq(row.fetch("employer_contributions_total").to_d)
    expect(row.keys).not_to include("check_number")
    expect(row.fetch("additional_withholding_override").to_d).to eq(12.34.to_d)
    expect(row.fetch("payroll_adjustments").sole.fetch("notes")).to eq("Internal test memo")
    expect(response.body).not_to include("TEST-100")

    get "/api/v1/client/reports/payroll_register_pdf", params: params
    expect(response).to have_http_status(:ok)
    pdf = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ").squish
    expect(pdf).to include(company.name, "Regular Hours 70.25", "Overtime Hours 4.50",
      "Bonus $42.67", "Total Guam income tax withheld $132.34", "Employer Payroll Cost $1,584.20")
    expect(pdf).not_to include("TEST-100")

    get "/api/v1/client/reports/payroll_register_csv", params: params
    expect(response).to have_http_status(:ok)
    row = CSV.parse(response.body, headers: true)[-1]
    expect(row.fetch("Regular Hours").to_d).to eq(summary.fetch("total_hours").to_d)
    expect(row.fetch("Total Guam income tax withheld")).to eq("132.34")
    expect(response.body).not_to include("TEST-100")

    get "/api/v1/client/reports/payroll_register_xlsx", params: params
    expect(response).to have_http_status(:ok)
    workbook = Roo::Excelx.new(StringIO.new(response.body))
    rows = workbook.sheet("Employees").to_a
    expect(rows.last.fetch(rows.fetch(3).index("Regular Hours")).to_d).to eq(summary.fetch("total_hours").to_d)
    expect(rows.last.fetch(rows.fetch(3).index("Total Guam income tax withheld"))).to eq(132.34)
    expect(workbook.sheets.flat_map { |name| workbook.sheet(name).to_a.flatten }).not_to include("TEST-100")
    expect(workbook.sheet("Payroll Adjustments Detail").column(8)).to include("Internal test memo")
  end

  it "exports the client payroll register in CSV and Excel from the same committed snapshot" do
    get "/api/v1/client/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("text/csv")
    csv_rows = CSV.parse(response.body)
    expect(csv_rows.flatten).to include("Ana Perez", "75.00")

    get "/api/v1/client/reports/payroll_register_xlsx", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("spreadsheetml")
    workbook = Roo::Excelx.new(StringIO.new(response.body))
    expect(workbook.sheets).to include("Employees", "Payroll Fields Detail", "Payroll Fields Totals")
  end

  it "does not export a draft payroll register to client users" do
    %w[payroll_register_csv payroll_register_pdf payroll_register_xlsx].each do |action|
      get "/api/v1/client/reports/#{action}", params: { pay_period_id: draft_pay_period.id }

      expect(response).to have_http_status(:not_found), "expected #{action} to reject a draft pay period"
    end
  end

  it "limits ytd summary to committed pay periods" do
    create_client_historical_paycheck(employee: employee, suffix: "linked")
    create_client_historical_paycheck(employee: nil, suffix: "unlinked", gross_pay: 125, net_pay: 90)

    get "/api/v1/client/reports/ytd_summary", params: { year: 2026 }

    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    expect(report.dig("company_totals", "gross_pay").to_f).to eq(1850.0)
    expect(report.dig("company_totals", "custom_earnings_total").to_f).to eq(50.0)
    expect(report.dig("company_totals", "custom_deductions_total").to_f).to eq(30.0)
    expect(report.dig("company_totals", "payroll_field_post_tax_deductions_total").to_f).to eq(75.0)
    expect(report.fetch("employees").first.fetch("gross_pay").to_f).to eq(1850.0)
    expect(report.fetch("employees").first.fetch("custom_earnings_total").to_f).to eq(50.0)
    expect(report.fetch("employees").first.fetch("custom_deductions_total").to_f).to eq(30.0)
    expect(report.fetch("employees").first.fetch("payroll_field_post_tax_deductions_total").to_f).to eq(75.0)
    expect(report.dig("payroll_fields", "totals", 0, "label")).to eq("Rent Deduction")
    expect(report.dig("payroll_fields", "entries", 0)).to include(
      "employee_name" => "Ana Perez",
      "label" => "Rent Deduction",
      "tax_treatment" => "post_tax_deduction",
      "source" => "manual"
    )
    expect(report.dig("payroll_fields", "entries", 0, "amount").to_f).to eq(75.0)
    expect(report.dig("source_summary", "quickbooks")).to include(
      "payroll_count" => 1,
      "paycheck_count" => 1,
      "excluded_unlinked_paycheck_count" => 1,
      "excluded_unlinked_gross_pay" => 125.0
    )
    expect(report.dig("source_summary", "source_statement")).to include("not recalculated")
  end

  it "exports the client payroll summary as PDF, Excel, and CSV with matching totals" do
    get "/api/v1/client/reports/ytd_summary_csv", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    csv_rows = CSV.parse(response.body)
    ana_row = csv_rows.find { |row| row.include?("Ana Perez") }
    expect(ana_row).to include("1450.0")

    get "/api/v1/client/reports/ytd_summary_xlsx", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    workbook = Roo::Excelx.new(StringIO.new(response.body))
    expect(workbook.sheets).to include("Payroll Summary", "Company Totals", "Payroll Sources", "Payroll Field Activity")

    get "/api/v1/client/reports/ytd_summary_pdf", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    reader = PDF::Reader.new(StringIO.new(response.body))
    text = reader.pages.map(&:text).join("\n")
    expect(text).to include("Payroll Summary by Pay Date")
    expect(text).to include("Ana Perez")
    expect(text).to include("Rent Deduction")
  end

  it "lets a client hide active employees with $0 pay without changing company totals" do
    unpaid = create(:employee, company: company, department: department, first_name: "No", last_name: "Pay")

    get "/api/v1/client/reports/ytd_summary", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("report", "employees").map { |row| row.fetch("employee_id") }).to include(unpaid.id)

    get "/api/v1/client/reports/ytd_summary", params: { year: 2026, include_zero_pay: false }
    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    expect(report.fetch("employees").map { |row| row.fetch("employee_id") }).not_to include(unpaid.id)
    expect(report.fetch("employees").map { |row| row.fetch("employee_id") }).to include(employee.id)
    expect(BigDecimal(report.dig("company_totals", "gross_pay").to_s)).to eq(BigDecimal("1450.00"))

    get "/api/v1/client/reports/ytd_summary_csv", params: { year: 2026, include_zero_pay: false }
    expect(response).to have_http_status(:ok)
    csv_names = CSV.parse(response.body, headers: true).map { |row| row.fetch("Employee Name") }
    expect(csv_names).to include(employee.full_name)
    expect(csv_names).not_to include(unpaid.full_name)

    get "/api/v1/client/reports/ytd_summary_xlsx", params: { year: 2026, include_zero_pay: false }
    expect(response).to have_http_status(:ok)
    workbook_names = Roo::Excelx.new(StringIO.new(response.body)).sheet("Payroll Summary").column(3)
    expect(workbook_names).to include(employee.full_name)
    expect(workbook_names).not_to include(unpaid.full_name)

    get "/api/v1/client/reports/ytd_summary_pdf", params: { year: 2026, include_zero_pay: false }
    expect(response).to have_http_status(:ok)
    pdf_text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(pdf_text).to include(employee.full_name)
    expect(pdf_text).not_to include(unpaid.full_name)
  end

  it "allows client users to review and export year-by-year payroll totals" do
    create_client_historical_paycheck(employee: employee, suffix: "annual-linked")

    get "/api/v1/client/reports/annual_payroll_summary"
    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    expect(report.fetch("years").pluck("year")).to eq([ 2026 ])
    expect(report.dig("years", 0, "cornerstone_payroll_count")).to eq(1)
    expect(report.dig("years", 0, "quickbooks_payroll_count")).to eq(1)
    expect(report.dig("totals", "gross_pay").to_f).to eq(1_850.0)

    %w[csv pdf xlsx].each do |format|
      get "/api/v1/client/reports/annual_payroll_summary_#{format}"
      expect(response).to have_http_status(:ok), "expected client #{format} export to succeed"
    end
  end

  describe "PDF exports with accented and non-Latin names" do
    before do
      employee.update!(first_name: "Aleksandra", last_name: "Wiśniewska-Kowalczyk")
      second = create(:employee, company: company, department: department, first_name: "Hương", last_name: "Nguyễn")
      create(:payroll_item, pay_period: pay_period, employee: second, company: company, gross_pay: 900.0, net_pay: 780.0,
        withholding_tax: 50.0, social_security_tax: 55.8, employer_social_security_tax: 55.8, medicare_tax: 13.05,
        employer_medicare_tax: 13.05, total_deductions: 120.0)
    end

    it "downloads the payroll register, payroll summary and annual totals PDFs" do
      get "/api/v1/client/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }
      expect(response).to have_http_status(:ok), response.body
      expect(unicode_pdf_text(response.body)).to include("Wiśniewska", "Nguyễn", "Hương")

      get "/api/v1/client/reports/ytd_summary_pdf", params: { year: 2026 }
      expect(response).to have_http_status(:ok), response.body
      expect(unicode_pdf_text(response.body)).to include("Wiśniewska", "Nguyễn")

      get "/api/v1/client/reports/annual_payroll_summary_pdf"
      expect(response).to have_http_status(:ok), response.body
    end

    it "returns a clear JSON error, not a dropped connection, when a PDF cannot be built" do
      allow_any_instance_of(PayrollRegisterPdfGenerator).to receive(:generate)
        .and_raise(Prawn::Errors::IncompatibleStringEncoding, "not Windows-1252")

      get "/api/v1/client/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:internal_server_error)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body).to eq(
        "error" => PdfGenerationFailureHandling::MESSAGE, "code" => "pdf_generation_failed"
      )
      expect(response.body).not_to include("Windows-1252")
    end
  end
end
