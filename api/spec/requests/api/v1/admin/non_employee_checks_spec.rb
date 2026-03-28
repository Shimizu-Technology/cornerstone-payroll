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
  end
end
