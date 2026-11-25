# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Refused employee email reasons", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:admin) { create(:user, company: company, organization: organization, role: "admin", email: "staff-reason@example.test") }
  let!(:employee) { create(:employee, company: company, first_name: "Sample", last_name: "Worker", email: nil) }

  before { allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin) }

  def save_email(record, email, company_id: record.company_id)
    patch "/api/v1/admin/employees/#{record.id}", headers: { "X-Company-Id" => company_id.to_s },
      params: { employee: { email: email } }
  end

  def reason
    response.parsed_body.dig("contact_validation", "email_error_code")
  end

  it "names a marked placeholder and a malformed address" do
    EmployeePlaceholderEmail.create!(organization: organization, email: "front-desk@client.example", marked_by: admin)

    save_email(employee, "front-desk@client.example")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(reason).to eq("placeholder_email")

    save_email(employee, "not-an-address@nowhere")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(reason).to eq("invalid_email")
    expect(employee.reload.email).to be_nil
  end

  it "adds no reason when the email saves or a login conflict refuses it" do
    save_email(employee, "sample.worker@example.test")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).not_to have_key("contact_validation")

    other = create(:employee, company: company, email: nil)
    login = create(:user, company: company, organization: organization, role: "client", email: "client-login@example.test")
    CompanyAssignment.create!(user: login, company: company)
    save_email(other, login.email)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("contact_validation")).not_to have_key("email_error_code")
  end

  context "when the company only sends to approved addresses" do
    let(:limited) { create_demo_company(organization: organization) }
    let!(:limited_employee) do
      create(:employee, company: limited, department: create(:department, company: limited), first_name: "Robin", last_name: "Lantern", email: nil)
    end

    before do
      CompanyAssignment.create!(user: admin, company: limited)
      EmployeePlaceholderEmail.create!(organization: organization, email: "front-desk@sample-client.com", marked_by: admin)
    end

    it "says the address can't be used without revealing the organization's placeholder list" do
      save_email(limited_employee, "someone@sample-client.com")
      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(reason).to eq("recipient_not_allowed")

      save_email(limited_employee, "front-desk@sample-client.com")
      expect(reason).to eq("recipient_not_allowed")

      save_email(limited_employee, "noemail@sample-client.com")
      expect(reason).to eq("placeholder_email")
      expect(response.body).not_to match(/demo/i)
    end

    context "with marked placeholders that pass the recipient check" do
      around do |example|
        saved = ENV[DemoOutbound::ENV_KEY]
        ENV[DemoOutbound::ENV_KEY] = "approved.sample@sample-client.com"
        example.run
      ensure
        ENV[DemoOutbound::ENV_KEY] = saved
      end

      before do
        EmployeePlaceholderEmail.create!(organization: organization, email: "marked.sample@sample-client.test", marked_by: admin)
        EmployeePlaceholderEmail.create!(organization: organization, email: "approved.sample@sample-client.com", marked_by: admin)
      end

      def saved_shape
        body = response.parsed_body
        [
          response.status, body.key?("contact_validation"), body.dig("contact_validation", "email_error_code"),
          body.dig("data", "contact_details_status", "email_issue"), body["contact_warnings"]
        ]
      end

      it "answers a marked address exactly like an unmarked one" do
        save_email(limited_employee, "unmarked.sample@sample-client.test")
        expect(response).to have_http_status(:ok), response.body
        unmarked = saved_shape
        expect(response.parsed_body.dig("data", "contact_details_status")).to be_present

        save_email(limited_employee, "marked.sample@sample-client.test")
        expect(saved_shape).to eq(unmarked)
        expect(limited_employee.reload.email).to eq("marked.sample@sample-client.test")

        save_email(limited_employee, "approved.sample@sample-client.com")
        expect(saved_shape).to eq(unmarked)
        expect(response.body).not_to include("placeholder_email")
      end

      it "still names a marked address for a live company" do
        save_email(employee, "marked.sample@sample-client.test")
        expect(response).to have_http_status(:unprocessable_entity)
        expect(reason).to eq("placeholder_email")
      end
    end
  end
end
