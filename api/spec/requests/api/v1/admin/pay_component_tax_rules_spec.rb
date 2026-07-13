# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayComponentTaxRules", type: :request do
  let(:company) { create(:company) }
  let(:admin_user) { create(:user, company: company, organization: company.organization, role: "admin") }

  let(:valid_attributes) do
    {
      component_key: "bonus",
      display_name: "Bonus",
      component_kind: "earning",
      fit_treatment: "taxable",
      social_security_treatment: "taxable",
      medicare_treatment: "taxable",
      additional_medicare_treatment: "taxable",
      swica_treatment: "included",
      retirement_treatment: "included",
      reimbursement_treatment: "not_applicable",
      register_presentation: "separate",
      effective_from: "2026-01-01",
      source_name: "Approved company policy",
      source_url: "https://example.test/source",
      version: "1"
    }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayComponentTaxRulesController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayComponentTaxRulesController)
      .to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::PayComponentTaxRulesController)
      .to receive(:current_user).and_return(admin_user)
  end

  it "lists the effective default snapshot and configured company rules" do
    rule = company.pay_component_tax_rules.create!(valid_attributes)

    get "/api/v1/admin/pay_component_tax_rules", params: { effective_on: "2026-07-01" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("effective_rule_snapshot", "rules")).to include(
      include("component_key" => "bonus", "id" => rule.id, "source" => "database")
    )
    expect(response.parsed_body.fetch("configured_rules").sole).to include(
      "id" => rule.id,
      "immutable_after_use" => false
    )
  end

  it "creates an approved company-scoped effective-dated rule" do
    post "/api/v1/admin/pay_component_tax_rules", params: { pay_component_tax_rule: valid_attributes }

    expect(response).to have_http_status(:created)
    rule = company.pay_component_tax_rules.sole
    expect(rule.approved_by_id).to eq(admin_user.id)
    expect(rule.approved_at).to be_present
  end

  it "rejects overlapping versions" do
    company.pay_component_tax_rules.create!(valid_attributes.merge(effective_to: "2026-12-31"))

    post "/api/v1/admin/pay_component_tax_rules", params: {
      pay_component_tax_rule: valid_attributes.merge(effective_from: "2026-06-01", version: "2")
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("errors").join).to include("overlaps")
  end

  it "prevents editing a rule after a committed liability posting references it" do
    rule = company.pay_component_tax_rules.create!(valid_attributes)
    department = create(:department, company: company)
    employee = create(:employee, company: company, department: department)
    period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 7, 15))
    create(:payroll_item,
      pay_period: period,
      employee: employee,
      company: company,
      bonus: 100,
      withholding_tax: 10)
    posting = PayrollLiabilityPostingService.post!(pay_period: period, actor: admin_user)
    PayrollLiabilityEntry.where(id: posting.entries.first.id).update_all(pay_component_tax_rule_id: rule.id)

    patch "/api/v1/admin/pay_component_tax_rules/#{rule.id}", params: {
      pay_component_tax_rule: { display_name: "Changed Bonus" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("Create a new effective-dated version")
    expect(rule.reload.display_name).to eq("Bonus")
  end

  it "does not expose or update rules from another company" do
    other_company = create(:company)
    other_rule = other_company.pay_component_tax_rules.create!(valid_attributes.merge(component_key: "commission"))

    patch "/api/v1/admin/pay_component_tax_rules/#{other_rule.id}", params: {
      pay_component_tax_rule: { display_name: "Cross-company edit" }
    }

    expect(response).to have_http_status(:not_found)
    expect(other_rule.reload.display_name).to eq("Bonus")
  end
end
