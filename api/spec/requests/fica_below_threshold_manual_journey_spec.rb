# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Manual client payroll with prior financial voids", type: :request do
  it "calculates, approves and commits a Spike-like chain, preserving saved amounts and open history review" do
    create(:tax_table, tax_year: 2026, ss_wage_base: 184500)
    company = create(:company, name: "Synthetic Spike-like manual client", auto_create_fit_check: false)
    actor = create(:user, company: company, role: "admin")
    employee = create(:employee, company: company, department: create(:department, company: company), pay_rate: 15,
      hire_date: "2026-01-01", payment_delivery_method: "paper_check")
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(actor.id)
    [ "voided", nil ].each do |status|
      prior = create(:pay_period, :committed, company: company, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-16")
      prior.update_columns(correction_status: status)
      create(:payroll_item, company: company, employee: employee, pay_period: prior, hours_worked: 0,
        gross_pay: 1000, reported_tips: 100, net_pay: "923.50", social_security_tax: 62, employer_social_security_tax: 62,
        medicare_tax: "14.50", employer_medicare_tax: "14.50", additional_medicare_tax: 0,
        social_security_taxable_wages: nil, social_security_taxable_tips: nil, additional_medicare_taxable_wages: nil,
        medicare_taxable_wages: nil, tax_rule_snapshot: {})
    end
    EmployeeYearFicaSourceReview.record!(employee: employee, actor: actor, tax_year: 2026, through_pay_date: "2026-11-15",
      external_ss_wage_bound: 0, external_medicare_wage_bound: 0, review_reference: "Synthetic complete external/predecessor wage review")
    run = create(:pay_period, company: company, start_date: "2026-10-16", end_date: "2026-10-31", pay_date: "2026-11-15")
    item = create(:payroll_item, company: company, employee: employee, pay_period: run, hours_worked: 0, bonus: 450, reported_tips: 50)

    post "/api/v1/admin/pay_periods/#{run.id}/run_payroll", params: { employee_ids: [ employee.id ] }
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload.status).to eq("calculated"), response.body
    expect(item.reload).to have_attributes(gross_pay: 500.to_d, social_security_tax: 31.to_d, medicare_tax: "7.25".to_d, net_pay: "461.75".to_d)
    expect(JSON.parse(response.body).dig("pay_period", "compliance_warnings").join).to include("Prior-period void history")
    post "/api/v1/admin/pay_periods/#{run.id}/approve"
    expect(response).to have_http_status(:ok), response.body
    post "/api/v1/admin/pay_periods/#{run.id}/commit"
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload).to be_committed
    expect(item.reload).to have_attributes(social_security_tax: 31.to_d, employer_social_security_tax: 31.to_d,
      medicare_tax: "7.25".to_d, employer_medicare_tax: "7.25".to_d, net_pay: "461.75".to_d)
    expect(item.tax_rule_snapshot.fetch("annual_fica_context")).to include("history_review_open" => true, "filing_review_open" => true)
    expect(PayrollItemFicaBasisProof.count).to eq(0)
  end
end
