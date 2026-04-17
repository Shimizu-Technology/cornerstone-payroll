require "rails_helper"

RSpec.describe "Api::V1::Admin::NonEmployeeChecks", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company) }
  let!(:pay_period) { create(:pay_period, company: company) }
  let!(:other_pay_period) { create(:pay_period, company: other_company) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "non-employee-checks-admin@example.com",
      name: "Checks Admin",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::NonEmployeeChecksController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::NonEmployeeChecksController).to receive(:current_user).and_return(admin_user)
  end

  describe "POST /api/v1/admin/non_employee_checks" do
    let(:valid_params) do
      {
        non_employee_check: {
          pay_period_id: pay_period.id,
          payable_to: "Island Vendor",
          amount: 125.50,
          check_type: "vendor",
          memo: "Office supplies"
        }
      }
    end

    it "creates a check for the current company pay period" do
      expect {
        post "/api/v1/admin/non_employee_checks", params: valid_params, as: :json
      }.to change(NonEmployeeCheck, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(NonEmployeeCheck.last.pay_period_id).to eq(pay_period.id)
    end

    it "rejects a pay period from another company on create" do
      expect {
        post "/api/v1/admin/non_employee_checks",
          params: {
            non_employee_check: valid_params[:non_employee_check].merge(pay_period_id: other_pay_period.id)
          },
          as: :json
      }.not_to change(NonEmployeeCheck, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/admin/non_employee_checks/:id" do
    let!(:check) do
      NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Island Vendor",
        amount: 125.50,
        check_type: "vendor",
        memo: "Office supplies"
      )
    end

    it "rejects changing the pay period to another company" do
      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: { pay_period_id: other_pay_period.id }
        },
        as: :json

      expect(response).to have_http_status(:not_found)
      expect(check.reload.pay_period_id).to eq(pay_period.id)
    end

    it "creates an audit log entry capturing changed fields and reason" do
      expect {
        patch "/api/v1/admin/non_employee_checks/#{check.id}",
          params: {
            non_employee_check: { payable_to: "Island Vendor LLC", amount: 200.00 },
            reason: "Vendor renamed and invoice updated"
          },
          as: :json
      }.to change(NonEmployeeCheckEdit, :count).by(1)

      expect(response).to have_http_status(:ok)

      edit = NonEmployeeCheckEdit.last
      expect(edit.changed_fields).to match_array(%w[payable_to amount])
      expect(edit.before["payable_to"]).to eq("Island Vendor")
      expect(edit.after["payable_to"]).to eq("Island Vendor LLC")
      expect(edit.before["amount"]).to eq("125.5")
      expect(edit.after["amount"]).to eq("200.0")
      expect(edit.reason).to eq("Vendor renamed and invoice updated")
      expect(edit.edited_by_id).to eq(admin_user.id)
    end

    it "does not create an audit entry when no audited fields actually change" do
      expect {
        patch "/api/v1/admin/non_employee_checks/#{check.id}",
          params: { non_employee_check: { payable_to: check.payable_to } },
          as: :json
      }.not_to change(NonEmployeeCheckEdit, :count)
    end

    it "rejects updates to a voided check" do
      check.update!(voided: true, voided_at: Time.current, void_reason: "test")

      expect {
        patch "/api/v1/admin/non_employee_checks/#{check.id}",
          params: { non_employee_check: { amount: 50.00 } },
          as: :json
      }.not_to change(NonEmployeeCheckEdit, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/admin/non_employee_checks/:id/history" do
    let!(:check) do
      NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Island Vendor",
        amount: 125.50,
        check_type: "vendor"
      )
    end

    it "returns the edits for the check, newest first" do
      check.edits.create!(
        edited_by: admin_user,
        before: { "amount" => "125.5" },
        after: { "amount" => "150.0" },
        changed_fields: ["amount"],
        reason: "Older edit"
      )
      check.edits.create!(
        edited_by: admin_user,
        before: { "amount" => "150.0" },
        after: { "amount" => "175.0" },
        changed_fields: ["amount"],
        reason: "Newer edit"
      )

      get "/api/v1/admin/non_employee_checks/#{check.id}/history"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["history"].length).to eq(2)
      expect(json["history"].first["reason"]).to eq("Newer edit")
      expect(json["history"].last["reason"]).to eq("Older edit")
    end
  end
end
