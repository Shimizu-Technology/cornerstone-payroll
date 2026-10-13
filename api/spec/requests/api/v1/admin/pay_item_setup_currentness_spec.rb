# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Recurring setup calculation currentness", type: :request do
  let!(:company) { create(:company) }
  let!(:employee) { create(:employee, company: company) }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let!(:field) { create(:payroll_field_definition, company: company, owner_employee: employee, default_amount: 250) }
  let!(:assignment) { employee.employee_payroll_fields.create!(payroll_field_definition: field, amount: 250) }
  let(:path) { "/api/v1/admin/employees/#{employee.id}/payroll_fields" }

  before do
    [ Api::V1::Admin::PayrollFieldsController, Api::V1::Admin::EmployeePayrollFieldsController, Api::V1::Admin::EmployeesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(controller).to receive(:current_user).and_return(accountant)
    end
  end

  def calculated_period(status: "calculated", pay_date: Date.new(2026, 10, 15), recurring: true, source: "employee_default")
    period = create(:pay_period, company: company, status: "calculated", calculated_at: Time.current,
      start_date: pay_date - 14, end_date: pay_date - 1, pay_date: pay_date,
      run_purpose: recurring ? "regular" : "bonus", includes_recurring_items: recurring)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period,
      gross_pay: 1250, net_pay: 1100, hours_worked: 80)
    entry = create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, amount: 250, source: source)
    package = PayrollReview::RevisionService.new(pay_period: period, actor: accountant).issue!
    period.update!(status: status, approved_at: status == "approved" ? Time.current : nil, approved_by_id: status == "approved" ? accountant.id : nil)
    [ period, item, entry, package ]
  end

  %w[calculated approved].each do |status|
    it "invalidates #{status} payroll on 250 to 300 and blocks stale approval and commit without modifying its worksheet" do
      period, item, entry, package = calculated_period(status: status)
      old_item, old_entry = item.attributes, entry.attributes
      patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([ period.id ])
      expect(period.reload).to be_draft
      expect(period.calculated_at).to be_nil
      expect(period.approved_at).to be_nil
      expect(period.approved_by_id).to be_nil
      expect(package.reload.status).to eq("superseded")
      expect(item.reload.attributes).to eq(old_item)
      expect(entry.reload.attributes).to eq(old_entry)
      lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: accountant)
      expect { lifecycle.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /calculated/)
      expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /approved/)
    end
  end

  it "invalidates an affected new addition while preserving an unchanged idempotent retry" do
    period, = calculated_period
    payload = { scope: "employee_only", payroll_field: { name: "New recurring allowance", kind: "addition", tax_treatment: "taxable_addition", amount_type: "fixed" }, employee_payroll_field: { amount: 75, start_date: "2026-10-15" } }
    post "#{path}/create_and_assign", params: payload, as: :json
    expect(response).to have_http_status(:created)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    post "#{path}/create_and_assign", params: payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
  end

  it "invalidates stop and reactivation and does not invalidate a no-op save" do
    period, = calculated_period
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 250 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
    delete "#{path}/#{assignment.id}"
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { active: true } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
  end

  it "invalidates a shared inherited amount change but preserves finalized snapshots" do
    # A new shared identity models a client library field rather than converting scope.
    shared = create(:payroll_field_definition, company: company, default_amount: 250)
    assignment.update!(payroll_field_definition: shared, amount: nil)
    period, item, entry, = calculated_period(status: "approved")
    finalized, final_item, final_entry, = calculated_period(status: "committed", pay_date: Date.new(2026, 9, 30))
    old_final_item, old_final_entry = final_item.attributes, final_entry.attributes
    patch "/api/v1/admin/payroll_fields/#{shared.id}", params: { payroll_field: { default_amount: 300 } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([ period.id ])
    expect(period.reload).to be_draft
    expect(item.reload.gross_pay).to eq(1250)
    expect(entry.reload.amount).to eq(250)
    expect(finalized.reload).to be_committed
    expect(final_item.reload.attributes).to eq(old_final_item)
    expect(final_entry.reload.attributes).to eq(old_final_entry)
  end

  it "invalidates shared archive and shared metadata used by a manual entry in a recurring-off run" do
    shared = create(:payroll_field_definition, company: company, default_amount: 250)
    assignment.update!(payroll_field_definition: shared)
    period, = calculated_period
    delete "/api/v1/admin/payroll_fields/#{shared.id}"
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    special, _, entry, = calculated_period(recurring: false, source: "manual")
    entry.update!(payroll_field_definition: shared)
    patch "/api/v1/admin/payroll_fields/#{shared.id}", params: { payroll_field: { name: "Shared renamed" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to eq([ special.id ])
    expect(special.reload).to be_draft
    expect(entry.reload.source).to eq("manual")
    expect(entry.amount).to eq(250)
  end

  it "leaves future or ended assignments, absent employees, and recurring-off automatic rows alone" do
    period, = calculated_period
    special, = calculated_period(recurring: false, pay_date: Date.new(2026, 10, 16))
    assignment.update!(start_date: Date.new(2026, 10, 20))
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
    assignment.update!(start_date: nil, end_date: Date.new(2026, 10, 14))
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 350 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    assignment.update!(end_date: nil)
    period.payroll_items.destroy_all
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 400 } }, as: :json
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(special.reload).to be_calculated
  end

  it "includes the last payday and old date range when ending an effective item" do
    assignment.update!(start_date: Date.new(2026, 10, 15), end_date: Date.new(2026, 10, 15))
    period, = calculated_period
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { end_date: "2026-10-14", start_date: nil } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
  end

  it "invalidates existing assignment and bulk update paths too" do
    period, = calculated_period
    patch "#{path}/#{assignment.id}", params: { employee_payroll_field: { amount: 300 } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    post "#{path}/bulk_update", params: { employee_payroll_fields: [ { id: assignment.id, payroll_field_definition_id: field.id, amount: 400 } ] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
  end

  it "invalidates legacy conversion when its automatic legacy snapshot can refresh" do
    legacy = { label: "Older allowance", amount: 75, treatment: "taxable_addition", active: true }
    employee.update!(default_payroll_adjustments: [ legacy ])
    period, item, = calculated_period
    item.update!(payroll_adjustments: [ legacy ])
    item.mark_payroll_adjustments_default_snapshot!
    item.save!
    post "#{path}/convert_legacy", params: {
      legacy: legacy.merge(kind: "adjustment"), payroll_field: { name: "Older allowance", category: "other" }, employee_payroll_field: { start_date: "2026-10-15" }
    }, as: :json
    expect(response).to have_http_status(:created)
    expect(period.reload).to be_draft
    expect(item.reload.payroll_adjustments.first["label"]).to eq("Older allowance")
  end
  it "invalidates removing a legacy profile default but leaves an ordinary profile edit alone" do
    legacy = { label: "Older allowance", amount: 750, treatment: "taxable_addition", active: true }
    employee.update!(default_payroll_adjustments: [ legacy ])
    period, item, = calculated_period(status: "approved")
    item.update!(payroll_adjustments: [ legacy ])
    item.mark_payroll_adjustments_default_snapshot!
    item.save!
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { first_name: "Updated" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_approved
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { default_payroll_adjustments: [] } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    expect(item.reload.payroll_adjustments.first["amount"]).to eq(750)
  end
  it "does not invalidate a shared default edit for an explicit zero override" do
    shared = create(:payroll_field_definition, company: company, default_amount: 250)
    assignment.update!(payroll_field_definition: shared, amount: 0)
    period, = calculated_period
    patch "/api/v1/admin/payroll_fields/#{shared.id}", params: { payroll_field: { default_amount: 300 } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["recalculation_pay_period_ids"]).to be_empty
    expect(period.reload).to be_calculated
  end

  it "covers legacy custom earnings removal and compatible personal creation" do
    employee.update!(default_custom_earnings: [ { label: "Legacy earning", amount: 50 } ])
    period, item, = calculated_period
    item.sync_default_custom_earnings!(employee)
    item.save!
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { default_custom_earnings: [] } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload).to be_draft
    period.update!(status: "calculated", calculated_at: Time.current)
    post "#{path}/create_personal", params: {
      payroll_field: { name: "Compatibility allowance", kind: "addition", tax_treatment: "taxable_addition" },
      employee_payroll_field: { amount: 50 }
    }, as: :json
    expect(response).to have_http_status(:created)
    expect(period.reload).to be_draft
  end

  it "rolls back the setup if invalidating a review package fails" do
    period, _, _, package = calculated_period
    allow_any_instance_of(PayPeriod).to receive(:invalidate_calculation!).and_raise(ActiveRecord::RecordInvalid.new(period))
    patch "#{path}/#{assignment.id}/pay_item", params: { employee_payroll_field: { amount: 300 } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(assignment.reload.amount).to eq(250)
    expect(period.reload).to be_calculated
    expect(package.reload.status).to eq("pending")
  end
end
