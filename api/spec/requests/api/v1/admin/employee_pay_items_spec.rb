# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee pay-item setup", type: :request do
  let!(:company) { create(:company) }
  let!(:employee) { create(:employee, company: company) }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let(:base_path) { "/api/v1/admin/employees/#{employee.id}/payroll_fields" }
  let(:field_attrs) { { name: "Role allowance", kind: "addition", tax_treatment: "taxable_addition", category: "other", amount_type: "fixed" } }
  let(:payload) { { scope: "employee_only", payroll_field: field_attrs, employee_payroll_field: { amount: 250, start_date: "2026-10-13", notes: "Authorized allowance" } } }

  before do
    [ Api::V1::Admin::PayrollFieldsController, Api::V1::Admin::EmployeePayrollFieldsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(controller).to receive(:current_user).and_return(accountant)
    end
  end

  def create_item(attributes = payload)
    post "#{base_path}/create_and_assign", params: attributes, as: :json
  end

  def edit_item(assignment, attributes)
    patch "#{base_path}/#{assignment.id}/pay_item", params: attributes, as: :json
  end

  it "atomically creates either scope as an accountant and leaves other employees unassigned" do
    colleague = create(:employee, company: company)
    %w[employee_only client_wide].each do |scope|
      create_item(payload.merge(scope: scope))
      expect(response).to have_http_status(:created)
      definition = PayrollFieldDefinition.find(response.parsed_body.dig("payroll_field", "id"))
      expect(definition.owner_employee_id).to eq(scope == "employee_only" ? employee.id : nil)
      expect(response.parsed_body.dig("employee_payroll_field", "amount")).to eq(250)
      expect(response.parsed_body.dig("employee_payroll_field", "payroll_field", "owner_employee_id")).to eq(definition.owner_employee_id)
      expect(response.parsed_body.dig("payroll_field", "active_assignment_count")).to eq(1)
      expect(response.parsed_body.dig("payroll_field", "assigned_employee_count")).to eq(1)
    end
    expect(colleague.employee_payroll_fields).to be_empty
  end

  it "returns the same identities on an exact double submit without duplicate allowance payments" do
    %w[employee_only client_wide].each do |scope|
      request_payload = payload.merge(scope: scope)
      create_item(request_payload)
      ids = response.parsed_body.values_at("payroll_field", "employee_payroll_field").map { |row| row["id"] }
      expect { create_item(request_payload) }.not_to change(PayrollFieldDefinition, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.values_at("payroll_field", "employee_payroll_field").map { |row| row["id"] }).to eq(ids)
    end
    expect(employee.employee_payroll_fields.count).to eq(2)
  end

  it "rejects conflicting retries and an existing unassigned shared name without overwriting setup" do
    create_item(payload.merge(scope: "client_wide"))
    assignment = employee.employee_payroll_fields.last
    create_item(payload.deep_merge(scope: "client_wide", employee_payroll_field: { amount: 500 }))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(assignment.reload.amount).to eq(250)
    coworker = create(:employee, company: company)
    post "/api/v1/admin/employees/#{coworker.id}/payroll_fields/create_and_assign", params: payload.merge(scope: "client_wide"), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(coworker.employee_payroll_fields).to be_empty
  end

  it "rolls back the definition if an assignment has an invalid or malformed payday" do
    [ { end_date: "2026-10-12" }, { start_date: "bad-date" } ].each do |attrs|
      expect { create_item(payload.deep_merge(employee_payroll_field: attrs)) }.not_to change(PayrollFieldDefinition, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.employee_payroll_fields).to be_empty
    end
  end

  it "rejects invalid scopes and attempted ownership or loan linkage injection" do
    [ payload.merge(scope: "everybody"), payload.deep_merge(payroll_field: { owner_employee_id: -1 }), payload.deep_merge(employee_payroll_field: { employee_loan_id: -1 }) ].each do |attrs|
      create_item(attrs)
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(PayrollFieldDefinition.count).to eq(0)
  end

  it "cannot create or edit pay items for another client or worker" do
    foreign_employee = create(:employee)
    post "/api/v1/admin/employees/#{foreign_employee.id}/payroll_fields/create_and_assign", params: payload, as: :json
    expect(response).to have_http_status(:not_found)
    create_item
    assignment = employee.employee_payroll_fields.last
    coworker = create(:employee, company: company)
    patch "/api/v1/admin/employees/#{coworker.id}/payroll_fields/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 10 } }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(assignment.reload.amount).to eq(250)
  end

  it "edits an owned definition and assignment together while preserving identity and finalized history" do
    create_item
    assignment = employee.employee_payroll_fields.last
    field = assignment.payroll_field_definition
    period = create(:pay_period, :committed, company: company)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period)
    entry = create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, label: "Role allowance", amount: 250)
    prior_snapshot = entry.attributes

    edit_item(assignment, payroll_field: { name: "Updated role allowance", default_amount: 300 }, employee_payroll_field: { amount: nil, start_date: "2026-10-15", notes: "Approved change" })
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("payroll_field", "id")).to eq(field.id)
    expect(response.parsed_body.dig("employee_payroll_field", "id")).to eq(assignment.id)
    expect(assignment.reload.amount).to be_nil
    expect(assignment.effective_amount_for(1000)).to eq(300)
    expect(entry.reload.attributes).to eq(prior_snapshot)
    expect(period.reload).to be_committed
  end

  it "keeps null inheritance distinct from explicit zero for amounts and percentages" do
    %w[fixed percentage].each do |type|
      definition = create(:payroll_field_definition, company: company, amount_type: type, default_amount: 125, default_percentage: 2)
      assignment = employee.employee_payroll_fields.create!(payroll_field_definition: definition, amount: 9, percentage: 9)
      edit_item(assignment, employee_payroll_field: { amount: nil, percentage: nil, notes: "Only note changed" })
      expect(response).to have_http_status(:ok)
      expect(assignment.reload.effective_amount_for(1000)).to eq(type == "fixed" ? 125 : 20)
      edit_item(assignment, employee_payroll_field: { amount: 0, percentage: 0 })
      expect(response).to have_http_status(:ok)
      expect(assignment.reload.effective_amount_for(1000)).to eq(0)
    end
  end

  it "allows changing only the selected worker's amount on a shared field" do
    definition = create(:payroll_field_definition, company: company, default_amount: 125)
    assignment = employee.employee_payroll_fields.create!(payroll_field_definition: definition)
    coworker = create(:employee, company: company)
    other_assignment = coworker.employee_payroll_fields.create!(payroll_field_definition: definition)
    edit_item(assignment, employee_payroll_field: { amount: 250 })
    expect(response).to have_http_status(:ok)
    expect(other_assignment.reload.amount).to be_nil
    expect(definition.reload.default_amount).to eq(125)
    edit_item(assignment, payroll_field: { name: "Wrong shared edit" }, employee_payroll_field: { amount: 400 })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(assignment.reload.amount).to eq(250)
    expect(definition.reload.name).not_to eq("Wrong shared edit")
  end

  it "rolls back personal metadata if assignment validation fails" do
    create_item
    assignment = employee.employee_payroll_fields.last
    edit_item(assignment, payroll_field: { name: "Unsaved rename" }, employee_payroll_field: { end_date: "2026-10-12" })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(assignment.payroll_field_definition.reload.name).to eq("Role allowance")
  end

  it "lists stopped items only when requested and allows personal reactivation" do
    create_item
    assignment = employee.employee_payroll_fields.last
    assignment.update!(active: false)
    assignment.payroll_field_definition.update!(active: false)
    get base_path
    expect(response.parsed_body["employee_payroll_fields"]).to be_empty
    get base_path, params: { include_inactive: true }
    expect(response.parsed_body["employee_payroll_fields"].size).to eq(1)
    edit_item(assignment, payroll_field: { active: true }, employee_payroll_field: { active: true })
    expect(response).to have_http_status(:ok)
    expect(assignment.reload).to be_active
    expect(assignment.payroll_field_definition.reload).to be_active
  end

  it "preserves tracked loan identity, amount and definition while permitting dates and notes" do
    loan = EmployeeLoan.create!(company: company, employee: employee, name: "Tracked debt", original_amount: 1000, current_balance: 1000, payment_amount: 100)
    definition = create(:payroll_field_definition, company: company, owner_employee: employee, kind: "deduction", tax_treatment: "post_tax_deduction", category: "loan")
    assignment = employee.employee_payroll_fields.create!(payroll_field_definition: definition, employee_loan: loan, amount: 100)
    [ { employee_loan_id: nil }, { payroll_field_definition_id: definition.id }, { amount: 101 } ].each do |attrs|
      edit_item(assignment, employee_payroll_field: attrs)
      expect(response).to have_http_status(:unprocessable_entity)
    end
    edit_item(assignment, payroll_field: { name: "Detached label" }, employee_payroll_field: { notes: "test" })
    expect(response).to have_http_status(:unprocessable_entity)
    edit_item(assignment, employee_payroll_field: { start_date: "2026-10-15", notes: "Verified", active: false })
    expect(response).to have_http_status(:ok)
    expect(assignment.reload.employee_loan_id).to eq(loan.id)
    expect(assignment.amount).to eq(100)
    expect(loan.reload.current_balance).to eq(1000)
  end

  it "lets accountants update and archive reusable fields while retaining loan treatment" do
    definition = create(:payroll_field_definition, company: company)
    patch "/api/v1/admin/payroll_fields/#{definition.id}", params: { payroll_field: { name: "Reusable updated" } }, as: :json
    expect(response).to have_http_status(:ok)
    delete "/api/v1/admin/payroll_fields/#{definition.id}"
    expect(response).to have_http_status(:ok)
    expect(definition.reload).not_to be_active
    patch "/api/v1/admin/payroll_fields/#{definition.id}", params: { payroll_field: { active: true } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(definition.reload).to be_active
  end

  it "serializes impact counts including inactive assignments without leaking private definitions" do
    definition = create(:payroll_field_definition, company: company)
    employee.employee_payroll_fields.create!(payroll_field_definition: definition)
    coworker = create(:employee, company: company)
    coworker.employee_payroll_fields.create!(payroll_field_definition: definition, active: false)
    get "/api/v1/admin/payroll_fields"
    field = response.parsed_body["payroll_fields"].first
    expect(field["active_assignment_count"]).to eq(1)
    expect(field["assigned_employee_count"]).to eq(2)
  end
end
