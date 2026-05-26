# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollItems", type: :request do
  let!(:organization) { create(:organization) }
  let!(:company) { create(:company, organization: organization) }
  let!(:admin_user) { create(:user, company: company, role: "admin") }
  let!(:employee) { create(:employee, company: company) }
  let!(:pay_period) { create(:pay_period, company: company, status: "calculated") }
  let!(:payroll_item) do
    create(
      :payroll_item,
      pay_period: pay_period,
      company: company,
      employee: employee,
      employment_type: employee.employment_type,
      pay_rate: employee.pay_rate
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollItemsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollItemsController).to receive(:current_user).and_return(admin_user)
  end

  describe "POST /api/v1/admin/pay_periods/:pay_period_id/payroll_items" do
    let(:create_params) do
      {
        employee_id: employee.id,
        payroll_item: {
          employment_type: employee.employment_type,
          pay_rate: employee.pay_rate,
          hours_worked: 8,
          overtime_hours: 0,
          holiday_hours: 0,
          pto_hours: 0
        }
      }
    end

    before do
      payroll_item.destroy!
    end

    it "clears an existing exclusion when the employee is re-added" do
      exclusion = PayPeriodExcludedEmployee.create!(pay_period: pay_period, employee: employee, excluded_by: admin_user)

      expect {
        post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items", params: create_params
      }.to change(PayrollItem, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(PayPeriodExcludedEmployee.where(id: exclusion.id)).not_to exist
      expect(pay_period.payroll_items.where(employee_id: employee.id)).to exist
    end

    it "rolls back the payroll item if clearing the exclusion fails" do
      exclusion = PayPeriodExcludedEmployee.create!(pay_period: pay_period, employee: employee, excluded_by: admin_user)
      allow_any_instance_of(PayPeriodExcludedEmployee).to receive(:destroy!)
        .and_raise(ActiveRecord::RecordNotDestroyed.new("Could not clear exclusion", exclusion))

      expect {
        post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items", params: create_params
      }.not_to change(PayrollItem, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(PayPeriodExcludedEmployee.where(id: exclusion.id)).to exist
      expect(pay_period.payroll_items.where(employee_id: employee.id)).not_to exist
    end

    it "returns a validation response if a concurrent add creates the same payroll item" do
      allow_any_instance_of(PayrollItem).to receive(:save!)
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint"))

      expect {
        post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items", params: create_params
      }.not_to change(PayrollItem, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch("errors").first).to include("duplicate key value")
    end
  end

  describe "PATCH /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id" do
    it "returns a validation response for stale payroll field entry ids" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan"
      )

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        payroll_item: {
          payroll_field_entries: [
            {
              id: 999_999,
              payroll_field_definition_id: field.id,
              label: "Loan",
              kind: "deduction",
              tax_treatment: "post_tax_deduction",
              category: "loan",
              amount: 10,
              active: true
            }
          ]
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch("errors").first).to include("Payroll field entry no longer exists")
    end
  end

  describe "DELETE /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id" do
    it "records the employee as excluded from the pay period" do
      expect {
        delete "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}"
      }.to change(PayPeriodExcludedEmployee, :count).by(1)

      expect(response).to have_http_status(:no_content)
      exclusion = PayPeriodExcludedEmployee.last
      expect(exclusion.pay_period_id).to eq(pay_period.id)
      expect(exclusion.employee_id).to eq(employee.id)
      expect(exclusion.excluded_by_id).to eq(admin_user.id)
      expect(pay_period.payroll_items.where(employee_id: employee.id)).not_to exist
    end

    it "rolls back the exclusion if removing the payroll item fails" do
      allow_any_instance_of(PayrollItem).to receive(:destroy!)
        .and_raise(ActiveRecord::RecordNotDestroyed.new("Could not remove payroll item", payroll_item))

      expect {
        delete "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}"
      }.not_to change(PayPeriodExcludedEmployee, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(pay_period.payroll_items.where(employee_id: employee.id)).to exist
    end
  end
end
