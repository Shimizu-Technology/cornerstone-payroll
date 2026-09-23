# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::RecordActivities", type: :request do
  let!(:organization) { create(:organization, name: "Activity Firm") }
  let!(:company) { create(:company, organization: organization, name: "Activity Client") }
  let!(:other_company) { create(:company, organization: organization, name: "Other Client") }
  let!(:actor) { create(:user, organization: organization, company: company, role: :manager, name: "Morgan Manager") }
  let!(:employee) { create(:employee, company: company, first_name: "Ada", last_name: "Payroll") }
  let!(:pay_period) { create(:pay_period, company: company) }

  before do
    allow_any_instance_of(Api::V1::Admin::RecordActivitiesController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::RecordActivitiesController).to receive(:current_user_id).and_return(actor.id)
    allow_any_instance_of(Api::V1::Admin::RecordActivitiesController).to receive(:current_company_id).and_return(company.id)
  end

  it "returns every supported employee alias in stable newest-first order" do
    occurred_at = Time.zone.parse("2026-09-23 09:30:00")
    first = create(
      :audit_log,
      user: actor,
      organization: organization,
      company: company,
      action: "employees#update",
      record_type: "Employee",
      record_id: employee.id,
      subject_name: employee.display_name,
      metadata: {
        changed_fields: [ "pay_rate" ],
        before_values: { pay_rate: "18.00" },
        after_values: { pay_rate: "20.00" },
        http_method: "PATCH",
        path: "/api/v1/admin/employees/#{employee.id}",
        response_status: 200
      },
      ip_address: "192.0.2.10",
      user_agent: "Example Browser",
      request_id: "request-activity-1",
      created_at: occurred_at
    )
    second = create(
      :audit_log,
      user: actor,
      organization: organization,
      company: company,
      action: "client_employees#update",
      record_type: "client_employees",
      record_id: employee.id,
      subject_name: employee.display_name,
      metadata: {
        http_method: "PATCH",
        path: "/api/v1/client/employees/#{employee.id}",
        response_status: 200
      },
      ip_address: "192.0.2.11",
      user_agent: "Example Client Browser",
      request_id: "request-activity-2",
      created_at: occurred_at
    )
    third = create(
      :audit_log,
      user: actor,
      organization: organization,
      company: company,
      action: "employees#update",
      record_type: "employees",
      record_id: employee.id,
      subject_name: employee.display_name,
      created_at: occurred_at + 1.minute
    )
    create(:audit_log, company: company, record_type: "departments", record_id: employee.id)
    create(:audit_log, company: other_company, record_type: "employees", record_id: employee.id)

    get "/api/v1/admin/record_activities/employees/#{employee.id}", params: { page: 1, per_page: 2 }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("data").pluck("id")).to eq([ third.id, second.id ])
    expect(body.fetch("meta")).to include(
      "current_page" => 1,
      "per_page" => 2,
      "total_count" => 3,
      "total_pages" => 2
    )
    expect(body.dig("data", 1, "id")).to be > first.id
    expect(body.dig("data", 0, "display_action")).to eq("Morgan Manager updated Ada Payroll")
    expect(body.dig("data", 1)).not_to include("actor_email", "ip_address", "request_id", "user_agent")
    expect(body.dig("data", 1, "metadata")).to include("response_status" => 200)
    expect(body.dig("data", 1, "metadata")).not_to include("http_method", "path")
  end

  it "returns pay-period activity for accountants" do
    accountant = create(:user, organization: organization, company: company, role: :accountant)
    allow_any_instance_of(Api::V1::Admin::RecordActivitiesController).to receive(:current_user).and_return(accountant)
    allow_any_instance_of(Api::V1::Admin::RecordActivitiesController).to receive(:current_user_id).and_return(accountant.id)
    log = create(
      :audit_log,
      user: actor,
      organization: organization,
      company: company,
      action: "pay_periods#approve",
      record_type: "PayPeriod",
      record_id: pay_period.id,
      ip_address: "192.0.2.20",
      user_agent: "Accountant Browser",
      request_id: "request-accountant-1",
      metadata: { http_method: "POST", path: "/api/v1/admin/pay_periods/#{pay_period.id}/approve" }
    )

    get "/api/v1/admin/record_activities/pay_periods/#{pay_period.id}"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ log.id ])
    expect(response.parsed_body.dig("data", 0)).to include(
      "actor_email" => actor.email,
      "ip_address" => "192.0.2.20",
      "user_agent" => "Accountant Browser",
      "request_id" => "request-accountant-1"
    )
    expect(response.parsed_body.dig("data", 0, "metadata")).to include("http_method" => "POST")
  end

  it "does not reveal records from another company" do
    foreign_employee = create(:employee, company: other_company)

    get "/api/v1/admin/record_activities/employees/#{foreign_employee.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.fetch("error")).to eq("Record not found")
  end

  it "rejects unsupported record types without querying arbitrary models" do
    get "/api/v1/admin/record_activities/users/#{actor.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "keeps record activity unavailable to client portal users" do
    client_user = create(:user, organization: organization, company: company, role: :client)
    allow_any_instance_of(Api::V1::Admin::RecordActivitiesController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Admin::RecordActivitiesController).to receive(:current_user_id).and_return(client_user.id)

    get "/api/v1/admin/record_activities/employees/#{employee.id}"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Staff access required")
  end
end
