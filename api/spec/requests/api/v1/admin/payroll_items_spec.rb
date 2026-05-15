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
  end
end
