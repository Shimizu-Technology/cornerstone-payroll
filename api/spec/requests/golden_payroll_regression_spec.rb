# frozen_string_literal: true

require "rails_helper"
require "yaml"

RSpec.describe "Golden payroll regression", type: :request do
  GOLDEN_FIXTURE_PATH = Rails.root.join("spec/fixtures/golden_payroll/biweekly_2026.yml")

  let(:expected) { YAML.safe_load_file(GOLDEN_FIXTURE_PATH) }
  let!(:organization) { create(:organization, name: "Golden Payroll Firm") }
  let!(:company) do
    create(
      :company,
      organization: organization,
      name: "Golden Payroll Company",
      ein: "66-1234567",
      address_line1: "100 Payroll Plaza",
      city: "Hagatna",
      state: "GU",
      zip: "96910",
      pay_frequency: "biweekly",
      next_check_number: 7000
    )
  end
  let!(:department) { create(:department, company: company, name: "Operations") }
  let!(:admin_user) do
    create(
      :user,
      company: company,
      email: "golden-payroll@example.com",
      name: "Golden Payroll Reviewer",
      role: "admin",
      active: true
    )
  end
  let!(:hourly_employee) do
    create(
      :employee,
      company: company,
      department: department,
      first_name: "Avery",
      last_name: "Hourly",
      ssn_encrypted: "900-81-0001",
      employment_type: "hourly",
      pay_rate: 20,
      pay_frequency: "biweekly",
      filing_status: "single",
      retirement_rate: 0
    )
  end
  let!(:salary_employee) do
    create(
      :employee,
      company: company,
      department: department,
      first_name: "Blake",
      last_name: "Salary",
      ssn_encrypted: "900-81-0002",
      employment_type: "salary",
      salary_type: "annual",
      pay_rate: 78_000,
      pay_frequency: "biweekly",
      filing_status: "single",
      retirement_rate: 0.04
    )
  end
  let!(:contractor) do
    create(
      :employee,
      :contractor,
      company: company,
      department: department,
      first_name: "Casey",
      last_name: "Contractor",
      ssn_encrypted: "900-81-0003",
      pay_rate: 750,
      pay_frequency: "biweekly",
      contractor_type: "individual",
      contractor_pay_type: "flat_fee",
      w9_on_file: true
    )
  end
  let!(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 1, 14),
      pay_date: Date.new(2026, 1, 16),
      run_purpose: "regular",
      includes_base_salary: true
    )
  end

  before do
    create_flat_tax_configuration!
    create(
      :information_return_threshold,
      form_type: "1099_nec",
      tax_year: 2026,
      threshold_amount: 600,
      effective_on: Date.new(2026, 1, 1)
    )

    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(admin_user.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(admin_user)

    calculate_approve_and_commit!
  end

  after { cleanup_quickbooks_history_uploads }

  it "reconciles the real calculation and commit pipeline to fixed expected paychecks" do
    items_by_name = pay_period.reload.payroll_items.includes(:employee).index_by { |item| item.employee.full_name }

    expect(items_by_name.keys).to contain_exactly(*expected.fetch("workers").keys)
    expected.fetch("workers").each do |name, worker_expected|
      item = items_by_name.fetch(name)

      expect(item.employment_type).to eq(worker_expected.fetch("employment_type")), name
      %w[
        hours_worked overtime_hours reported_tips tips_paid_out gross_pay withholding_tax
        social_security_tax medicare_tax retirement_payment total_deductions net_pay
      ].each do |field|
        expect(money(item.public_send(field))).to eq(money(worker_expected.fetch(field))), "#{name} #{field}"
      end

      employee_ytd = EmployeeYtdTotal.find_by!(employee: item.employee, year: 2026)
      %w[gross_pay net_pay withholding_tax social_security_tax medicare_tax].each do |field|
        expect(money(employee_ytd.public_send(field))).to eq(money(worker_expected.fetch(field))), "#{name} YTD #{field}"
      end
      expect(money(employee_ytd.retirement)).to eq(money(worker_expected.fetch("retirement_payment"))), "#{name} YTD retirement"
    end

    period_expected = expected.fetch("period")
    all_items = items_by_name.values
    w2_items = all_items.reject { |item| item.employment_type == "contractor" }
    contractor_items = all_items.select { |item| item.employment_type == "contractor" }

    expect(money(w2_items.sum(&:gross_pay))).to eq(period_expected.fetch("w2_gross"))
    expect(money(contractor_items.sum(&:gross_pay))).to eq(period_expected.fetch("contractor_gross"))
    expect(money(all_items.sum(&:gross_pay))).to eq(period_expected.fetch("total_gross"))
    expect(money(all_items.sum(&:net_pay))).to eq(period_expected.fetch("total_net"))
    expect(money(w2_items.sum(&:withholding_tax))).to eq(period_expected.fetch("withholding_tax"))
    expect(money(w2_items.sum(&:social_security_tax))).to eq(period_expected.fetch("social_security_tax"))
    expect(money(w2_items.sum(&:medicare_tax))).to eq(period_expected.fetch("medicare_tax"))
    expect(money(w2_items.sum(&:employer_social_security_tax))).to eq(period_expected.fetch("employer_social_security_tax"))
    expect(money(w2_items.sum(&:employer_medicare_tax))).to eq(period_expected.fetch("employer_medicare_tax"))
    expect(all_items.map(&:check_number)).to contain_exactly("7000", "7001", "7002")

    company_ytd = CompanyYtdTotal.find_by!(company: company, year: 2026)
    expect(money(company_ytd.gross_pay)).to eq(period_expected.fetch("total_gross"))
    expect(money(company_ytd.net_pay)).to eq(period_expected.fetch("total_net"))
    expect(money(company_ytd.withholding_tax)).to eq(period_expected.fetch("withholding_tax"))
    expect(money(company_ytd.social_security_tax)).to eq(period_expected.fetch("social_security_tax"))
    expect(money(company_ytd.medicare_tax)).to eq(period_expected.fetch("medicare_tax"))

    posting = pay_period.payroll_liability_postings.find_by!(posting_type: "commit")
    expect(money(posting.entries.sum(:amount))).to eq(period_expected.fetch("liability_total"))
    expect(posting.entries.where(component_key: "guam_income_tax_withheld").sum(:amount).to_f).to eq(period_expected.fetch("withholding_tax"))
  end

  it "ties the payroll register and YTD report to the committed payroll" do
    period_expected = expected.fetch("period")

    get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    register = response.parsed_body.fetch("report")

    expect(register.dig("summary", "employee_count")).to eq(2)
    expect(register.dig("summary", "contractor_count")).to eq(1)
    expect(money(register.dig("summary", "total_gross"))).to eq(period_expected.fetch("w2_gross"))
    expect(money(register.dig("summary", "contractor_total_gross"))).to eq(period_expected.fetch("contractor_gross"))
    expect(money(register.dig("summary", "total_net"))).to eq(period_expected.fetch("w2_net"))
    expect(money(register.dig("summary", "contractor_total_net"))).to eq(period_expected.fetch("contractor_net"))

    get "/api/v1/admin/reports/ytd_summary", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    ytd = response.parsed_body.fetch("report")

    expect(ytd.fetch("employees").size).to eq(3)
    expect(money(ytd.dig("company_totals", "gross_pay"))).to eq(period_expected.fetch("total_gross"))
    expect(money(ytd.dig("company_totals", "net_pay"))).to eq(period_expected.fetch("total_net"))
    expect(money(ytd.dig("company_totals", "withholding_tax"))).to eq(period_expected.fetch("withholding_tax"))
    expect(ytd.dig("company_totals", "payroll_count")).to eq(1)
  end

  it "keeps committed payroll, YTD balances, and live report values stable through a historical import" do
    before_snapshot = live_payroll_snapshot

    batch = QuickbooksHistory::ImportService.new(
      company: company,
      files: quickbooks_history_uploads,
      actor: admin_user
    ).call.batch
    review_historical_workers_as_archive_only(batch, actor: admin_user)
    lifecycle = QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin_user)
    lifecycle.apply!(acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT)
    lifecycle.lock!

    expect(batch.reload).to be_locked
    expect(batch.historical_paychecks.count).to eq(2)
    expect(live_payroll_snapshot).to eq(before_snapshot)
  end

  it "ties SWICA, Form 941, W-2GU, and 1099-NEC to the same committed snapshot" do
    quarterly_expected = expected.fetch("quarterly")
    annual_expected = expected.fetch("annual")

    get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 1 }
    expect(response).to have_http_status(:ok)
    quarterly = response.parsed_body.fetch("report")

    expect(quarterly.dig("swica", "totals", "employee_count")).to eq(quarterly_expected.fetch("swica_employee_count"))
    expect(money(quarterly.dig("swica", "totals", "total_wages"))).to eq(quarterly_expected.fetch("swica_wages"))
    expect(money(quarterly.dig("swica", "totals", "total_tax_withheld"))).to eq(quarterly_expected.fetch("swica_withholding"))
    expect(quarterly.dig("swica", "excluded_contractor_summary", "employee_count")).to eq(quarterly_expected.fetch("contractor_count_excluded"))
    expect(money(quarterly.dig("swica", "excluded_contractor_summary", "total_wages"))).to eq(quarterly_expected.fetch("contractor_wages_excluded"))
    expect(quarterly.dig("swica", "tie_out", "status")).to eq("ok")

    form_941 = quarterly.dig("federal_941", "report", "lines")
    expect(money(form_941.fetch("line5a_ss_wages"))).to eq(quarterly_expected.fetch("social_security_wages"))
    expect(money(form_941.fetch("line5b_ss_tips"))).to eq(quarterly_expected.fetch("social_security_tips"))
    expect(money(form_941.fetch("line5a_ss_combined_tax") + form_941.fetch("line5b_ss_tips_combined_tax"))).to eq(quarterly_expected.fetch("social_security_combined_tax"))
    expect(money(form_941.fetch("line5c_medicare_wages"))).to eq(quarterly_expected.fetch("medicare_wages"))
    expect(money(form_941.fetch("line5c_medicare_combined_tax"))).to eq(quarterly_expected.fetch("medicare_combined_tax"))

    get "/api/v1/admin/reports/w2_gu", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    w2 = response.parsed_body.fetch("report")
    expect(w2.dig("meta", "employee_count")).to eq(annual_expected.fetch("w2_employee_count"))
    expect(money(w2.dig("totals", "box1_wages_tips_other_comp"))).to eq(annual_expected.fetch("w2_box1"))
    expect(money(w2.dig("totals", "box2_federal_income_tax_withheld"))).to eq(annual_expected.fetch("w2_box2"))
    expect(money(w2.dig("totals", "box3_social_security_wages"))).to eq(annual_expected.fetch("w2_box3"))
    expect(money(w2.dig("totals", "box4_social_security_tax_withheld"))).to eq(annual_expected.fetch("w2_box4"))
    expect(money(w2.dig("totals", "box5_medicare_wages_tips"))).to eq(annual_expected.fetch("w2_box5"))
    expect(money(w2.dig("totals", "box6_medicare_tax_withheld"))).to eq(annual_expected.fetch("w2_box6"))
    expect(money(w2.dig("totals", "box7_social_security_tips"))).to eq(annual_expected.fetch("w2_box7"))
    expect(money(w2.dig("totals", "box12_code_d_total"))).to eq(annual_expected.fetch("w2_code_d"))
    expect(money(w2.dig("totals", "box12_code_tp_total"))).to eq(annual_expected.fetch("w2_code_tp"))

    get "/api/v1/admin/reports/form_1099_nec", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    form_1099 = response.parsed_body.fetch("report")
    expect(form_1099.dig("meta", "contractor_count")).to eq(annual_expected.fetch("contractor_count"))
    expect(form_1099.dig("meta", "reportable_count")).to eq(annual_expected.fetch("reportable_contractor_count"))
    expect(money(form_1099.dig("totals", "total_compensation"))).to eq(annual_expected.fetch("contractor_compensation"))
    expect(money(form_1099.dig("totals", "reportable_compensation"))).to eq(annual_expected.fetch("contractor_compensation"))
  end

  it "does not repeat a flat-fee contractor payment in a tips-only run" do
    tips_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 1, 15),
      end_date: Date.new(2026, 1, 28),
      pay_date: Date.new(2026, 1, 30),
      run_purpose: "off_cycle_tips",
      includes_base_salary: false
    )

    post "/api/v1/admin/pay_periods/#{tips_period.id}/run_payroll", params: {
      employee_ids: [ contractor.id ]
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    contractor_item = tips_period.reload.payroll_items.find_by!(employee: contractor)
    expect(contractor_item).to have_attributes(gross_pay: 0.to_d, net_pay: 0.to_d)
    expect(contractor_item.payroll_item_earnings.where(category: "contract_fee")).to be_empty
  end

  def create_flat_tax_configuration!
    annual_config = create(
      :annual_tax_config,
      tax_year: 2026,
      ss_wage_base: 184_500,
      ss_rate: 0.062,
      medicare_rate: 0.0145,
      additional_medicare_rate: 0.009,
      additional_medicare_threshold: 200_000,
      is_active: false
    )
    filing_config = create(
      :filing_status_config,
      annual_tax_config: annual_config,
      filing_status: "single",
      standard_deduction: 0
    )
    create(
      :tax_bracket,
      filing_status_config: filing_config,
      bracket_order: 1,
      min_income: 0,
      max_income: nil,
      rate: 0.10
    )
  end

  def calculate_approve_and_commit!
    post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
      employee_ids: [ hourly_employee.id, salary_employee.id, contractor.id ],
      hours: {
        hourly_employee.id.to_s => { regular: 72, overtime: 8 },
        salary_employee.id.to_s => { regular: 0, overtime: 0 },
        contractor.id.to_s => { regular: 0, overtime: 0 }
      },
      tips_paid_out: {
        hourly_employee.id.to_s => 120
      },
      payroll_adjustments: {
        hourly_employee.id.to_s => [
          { label: "Performance bonus", amount: 100, treatment: "taxable_addition", active: true },
          { label: "Mileage reimbursement", amount: 35, treatment: "non_taxable_addition", active: true },
          { label: "Approved pre-tax benefit", amount: 50, treatment: "pre_tax_deduction", active: true },
          { label: "Uniform repayment", amount: 25, treatment: "post_tax_deduction", active: true }
        ]
      }
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    expect(response.parsed_body.dig("results", "success").size).to eq(3)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/approve"
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"
    expect(response).to have_http_status(:ok)
    expect(pay_period.reload).to be_committed
  end

  def money(value)
    BigDecimal(value.to_s).round(2).to_f
  end

  def live_payroll_snapshot
    get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    register = response.parsed_body.fetch("report")
    get "/api/v1/admin/reports/ytd_summary", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    ytd_report = response.parsed_body.fetch("report")

    # Report generation timestamps describe each request, not payroll state.
    register["meta"]&.delete("generated_at")
    ytd_report["meta"]&.delete("generated_at")

    {
      pay_period: pay_period.reload.attributes,
      payroll_items: pay_period.payroll_items.order(:id).map(&:attributes),
      employee_ytd: EmployeeYtdTotal.where(employee_id: company.employees.select(:id)).order(:employee_id, :year).map(&:attributes),
      company_ytd: CompanyYtdTotal.where(company: company).order(:year).map(&:attributes),
      payroll_register: register,
      ytd_report: ytd_report
    }
  end
end
