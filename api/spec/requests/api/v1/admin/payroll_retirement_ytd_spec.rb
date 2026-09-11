# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Retirement YTD across batch payroll", type: :request do
  it "combines the historical bridge, prior fixed deductions, and current contributions exactly once" do
    company = create(:company)
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    employee = create(:employee, company: company, department: create(:department, company: company), hire_date: Date.new(2023, 1, 1))
    create(:tax_table)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(company: company, historical_import_batch: batch, status: "applied", plan_digest: "bootstrap-plan", applied_at: Time.current, applied_by: actor)
    bridge = HistoricalYtdBridge.create!(company: company, historical_import_batch: batch, historical_client_bootstrap: bootstrap,
      status: "applied", plan_digest: "bridge-plan", applied_at: Time.current, applied_by: actor,
      preview_summary: { "through_period_end" => "2024-01-01", "through_pay_date" => "2024-01-01" },
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT)
    balance = HistoricalEmployeeYtdBalance.create!(historical_ytd_bridge: bridge, company: company, employee: employee, tax_year: 2024,
      through_period_end: Date.new(2024, 1, 1), through_pay_date: Date.new(2024, 1, 1), retirement: 500, roth_retirement: 200)
    type = DeductionType.create!(company: company, name: "Fixed 401(k)", category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
    EmployeeDeduction.create!(employee: employee, deduction_type: type, amount: 75)
    prior = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 2))
    prior_item = create(:payroll_item, employee: employee, pay_period: prior)
    prior_item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: "pre_tax", reporting_group: "401k_pre_tax", amount: 100)
    current = create(:pay_period, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(actor.id)

    post "/api/v1/admin/pay_periods/#{current.id}/run_payroll", params: { hours: { employee.id.to_s => { regular: 80, overtime: 0 } } }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to be_blank
    calculated = current.reload.payroll_items.find_by!(employee: employee)
    expect(calculated.ytd_retirement).to eq(675.to_d)
    expect(calculated.ytd_roth_retirement).to eq(200.to_d)
    expect(balance.reload.retirement).to eq(500.to_d)
    expect(prior_item.reload.ytd_retirement).to eq(0.to_d)

    # A stale pre-fix ledger is corrected only on a financial write.
    ytd = employee.ytd_totals_for(2024)
    ytd.update!(retirement: 0, roth_retirement: 0)
    PayPeriodLifecycleService.new(pay_period: current, actor: actor).approve!
    PayPeriodLifecycleService.new(pay_period: current, actor: actor).commit!
    expect(ytd.reload).to have_attributes(retirement: 675.to_d, roth_retirement: 200.to_d)
    PayPeriodCorrectionService.void!(pay_period: prior, actor: actor, reason: "Testing old fixed contribution reversal")
    expect(ytd.reload).to have_attributes(retirement: 575.to_d, roth_retirement: 200.to_d)
    expect { PayPeriodCorrectionService.void!(pay_period: prior, actor: actor, reason: "Repeat") }.to raise_error(PayPeriodCorrectionService::AlreadyVoidedError)
    expect(ytd.reload.retirement).to eq(575.to_d)

    later = create(:pay_period, company: company, start_date: Date.new(2024, 1, 29), end_date: Date.new(2024, 2, 11), pay_date: Date.new(2024, 2, 16))
    post "/api/v1/admin/pay_periods/#{later.id}/run_payroll", params: { hours: { employee.id.to_s => { regular: 80, overtime: 0 } } }
    expect(response).to have_http_status(:ok)
    expect(later.reload.payroll_items.first.ytd_retirement).to eq(650.to_d)
    lifecycle = PayPeriodLifecycleService.new(pay_period: later, actor: actor)
    lifecycle.approve!
    allow(PayrollLiabilityPostingService).to receive(:post!).and_raise(StandardError, "Posting failed")
    expect { lifecycle.commit! }.to raise_error(StandardError, "Posting failed")
    expect(later.reload.status).to eq("approved")
    expect(ytd.reload.retirement).to eq(575.to_d)
    allow(PayrollLiabilityPostingService).to receive(:post!).and_call_original
    lifecycle.commit!
    expect(ytd.reload).to have_attributes(retirement: 650.to_d, roth_retirement: 200.to_d)
    expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError)
    expect(ytd.reload.retirement).to eq(650.to_d)
  end
end
