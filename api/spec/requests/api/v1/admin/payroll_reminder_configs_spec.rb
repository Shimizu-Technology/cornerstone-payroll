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

  context "staging test delivery" do
    around do |example|
      old_env = ENV.to_h
      ENV["DEPLOYMENT_ENV"] = "staging"
      ENV["STAGING_TESTER_BINDINGS"] = '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"}]'
      ENV["RESEND_FROM_EMAIL"] = "sender@example.test"
      ENV.delete("RESEND_API_KEY")
      ENV.delete("STAGING_MAIL_ALLOWLIST")
      example.run
    ensure
      ENV.replace(old_env)
    end

    before do
      accountant.update!(role: "admin")
      create(:payroll_reminder_config, company: company, enabled: true, recipients: [ "leon@example.test", "employee@example.test" ])
    end

    it "allows keyless capture and never reports captured messages as sent" do
      expect(Resend::Emails).not_to receive(:send)
      post "/api/v1/admin/payroll_reminder_config/test"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("sent" => 0, "captured" => 2, "failed" => 0)
      expect(response.parsed_body["message"]).to include("captured", "no email was sent")
    end

    it "reports mixed allowlisted delivery and capture counts accurately" do
      ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
      expect(Resend::Emails).to receive(:send).once.and_return({ "id" => "synthetic" })
      post "/api/v1/admin/payroll_reminder_config/test"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("sent" => 1, "captured" => 1, "failed" => 0)
    end

    it "redacts provider errors in the response and retains error-class evidence" do
      ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
      allow(Resend::Emails).to receive(:send).and_raise(RuntimeError, "PRIVATE_PROVIDER_MESSAGE")
      post "/api/v1/admin/payroll_reminder_config/test"
      expect(response.parsed_body).to include("sent" => 0, "captured" => 1, "failed" => 1)
      expect(response.body).not_to include("PRIVATE_PROVIDER_MESSAGE")
    end
  end
end
