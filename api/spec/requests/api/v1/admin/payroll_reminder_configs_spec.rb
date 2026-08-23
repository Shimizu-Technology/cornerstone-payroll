# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollReminderConfigs", type: :request do
  let(:company) { create(:company) }
  let(:accountant) do
    create(:user, company: company, organization: company.organization, role: "accountant")
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollReminderConfigsController)
      .to receive(:current_user).and_return(accountant)
    allow_any_instance_of(Api::V1::Admin::PayrollReminderConfigsController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollReminderConfigsController)
      .to receive(:current_company).and_return(company)
  end

  it "lets accountants inspect but not change reminder configuration" do
    get "/api/v1/admin/payroll_reminder_config"
    expect(response).to have_http_status(:ok)

    put "/api/v1/admin/payroll_reminder_config", params: {
      payroll_reminder_config: {
        enabled: true,
        days_before_due: 2,
        recipients: [ "payroll@example.test" ]
      }
    }

    expect(response).to have_http_status(:forbidden)
    expect(company.reload.payroll_reminder_config).to be_nil
  end
end
