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

    it "returns a validation response if field entry ids are submitted on create" do
      payroll_item.destroy!
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items", params: create_params.deep_merge(
        payroll_item: {
          payroll_field_entries: [
            {
              id: 123,
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
      )

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch("errors").first).to include("Payroll field entry IDs cannot be submitted")
    end

    it "returns a validation response for stale payroll field definitions" do
      payroll_item.destroy!

      post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items", params: create_params.deep_merge(
        payroll_item: {
          payroll_field_entries: [
            {
              payroll_field_definition_id: 999_999,
              label: "Stale Field",
              kind: "deduction",
              tax_treatment: "post_tax_deduction",
              category: "loan",
              amount: 10,
              active: true
            }
          ]
        }
      )

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch("errors").first).to include("Payroll field definition no longer exists")
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
    it "returns a validation response when auto-calculation fails validation after update" do
      allow_any_instance_of(PayrollItem).to receive(:calculate!)
        .and_raise(ActiveRecord::RecordInvalid.new(payroll_item))

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        auto_calculate: true,
        payroll_item: {
          hours_worked: 10
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to be_present
    end

    it "returns a validation response when update hits a payroll field entry uniqueness race" do
      allow_any_instance_of(PayrollItem).to receive(:update)
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint"))

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        payroll_item: {
          hours_worked: 10
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to include("duplicate key value")
    end

    it "does not mark field entries overridden when normalization filters every submitted entry" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Bonus",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Bonus",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount: 10,
        source: "employee_default"
      )

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        payroll_item: {
          payroll_field_entries: [
            {
              payroll_field_definition_id: field.id,
              label: "",
              kind: "addition",
              tax_treatment: "taxable_addition",
              category: "other",
              amount: 10,
              active: true
            }
          ]
        }
      }

      expect(response).to have_http_status(:ok)
      expect(payroll_item.reload.custom_columns_data || {}).not_to have_key("payroll_field_entries_overridden")
      expect(payroll_item.payroll_item_field_entries.active.count).to eq(1)
    end

    it "clears payroll field entry notes when blank notes are submitted" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan"
      )
      entry = payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount: 10,
        source: "manual",
        notes: "Clear me"
      )

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        payroll_item: {
          payroll_field_entries: [
            {
              id: entry.id,
              payroll_field_definition_id: field.id,
              label: "Loan",
              kind: "deduction",
              tax_treatment: "post_tax_deduction",
              category: "loan",
              amount: 10,
              notes: "",
              active: true
            }
          ]
        }
      }

      expect(response).to have_http_status(:ok)
      expect(entry.reload.notes).to be_nil
    end

    it "preserves capped-entry metadata when a submitted manual entry amount is unchanged" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan"
      )
      entry = payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount: 0,
        source: "employee_default",
        metadata: { "uncapped_amount" => 500.0 }
      )

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        payroll_item: {
          payroll_field_entries: [
            {
              id: entry.id,
              payroll_field_definition_id: field.id,
              label: "Loan",
              kind: "deduction",
              tax_treatment: "post_tax_deduction",
              category: "loan",
              amount: 0,
              source: "manual",
              active: true
            }
          ]
        }
      }

      expect(response).to have_http_status(:ok)
      expect(entry.reload.metadata).to include("uncapped_amount" => 500.0)
    end

    it "clears capped-entry metadata when an admin manually overrides the amount" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan"
      )
      entry = payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount: 0,
        source: "employee_default",
        metadata: { "uncapped_amount" => 500.0 }
      )

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        payroll_item: {
          payroll_field_entries: [
            {
              id: entry.id,
              payroll_field_definition_id: field.id,
              label: "Loan",
              kind: "deduction",
              tax_treatment: "post_tax_deduction",
              category: "loan",
              amount: 25,
              source: "manual",
              active: true
            }
          ]
        }
      }

      expect(response).to have_http_status(:ok)
      expect(entry.reload.amount.to_f).to eq(25.0)
      expect(entry.metadata).not_to have_key("uncapped_amount")
    end

    it "returns a validation response for stale payroll field definition ids" do
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}", params: {
        payroll_item: {
          payroll_field_entries: [
            {
              payroll_field_definition_id: 999_999,
              label: "Stale Field",
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
      expect(JSON.parse(response.body).fetch("errors").first).to include("Payroll field definition no longer exists")
    end

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

  describe "POST /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id/recalculate" do
    it "returns a validation response when recalculation fails validation" do
      allow_any_instance_of(PayrollItem).to receive(:calculate!)
        .and_raise(ActiveRecord::RecordInvalid.new(payroll_item))

      post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_items/#{payroll_item.id}/recalculate"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to be_present
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
