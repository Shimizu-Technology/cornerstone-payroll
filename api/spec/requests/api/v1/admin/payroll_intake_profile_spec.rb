# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll intake profile", type: :request do
  it "discovers enabled adapters through the same descriptor endpoint for different clients" do
    %w[mosa_revel spike_email].each do |adapter|
      company = create(:company, payroll_intake_source_types: [ adapter ])
      staff = create(:user, company: company, role: "admin")
      stub_portal_user(Api::V1::Admin::CompaniesController, staff, company)

      get "/api/v1/admin/companies/#{company.id}/intake_profile"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("adapters").pluck("key")).to eq([ adapter ])
    end
  end

  it "returns descriptor file slots, portal mapping, and client settings for mosa_revel" do
    company = create(
      :company,
      payroll_intake_source_types: [ "mosa_revel" ],
      payroll_intake_settings: { "mosa_revel" => { "required_sources" => [ "revel_hours" ] } }
    )
    staff = create(:user, company: company, role: "admin")
    stub_portal_user(Api::V1::Admin::CompaniesController, staff, company)

    get "/api/v1/admin/companies/#{company.id}/intake_profile", params: { on: "2026-07-15" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body).to include(
      "company_id" => company.id,
      "as_of" => "2026-07-15",
      "hours_source" => "intake_adapter",
      "intake_adapter" => "mosa_revel",
      "settings" => include(
        "tips_default" => "paid_in_check",
        "overtime_mode" => "source_reports",
        "workweek_alignment" => "warn_if_offset"
      )
    )

    adapter = body.fetch("adapters").sole
    expect(adapter).to include(
      "key" => "mosa_revel",
      "label" => "Revel hours + Cornerstone workbook",
      "parser_version" => "mosa_revel:v1",
      "extraction" => "deterministic",
      "accepts_pasted_text" => false,
      "reports_overtime" => true,
      "required_sources" => [ "revel_hours" ],
      "portal" => {
        "submittable" => true,
        "role_map" => {
          "revel_payroll" => "revel_hours",
          "changes_workbook" => "supplemental_workbook"
        }
      }
    )

    files = adapter.fetch("files").index_by { |slot| slot.fetch("role") }
    expect(files.fetch("revel_hours")).to include("required" => true, "accept" => [ ".pdf" ], "max" => 1)
    expect(files.fetch("supplemental_workbook")).to include(
      "required" => false,
      "required_by_default" => true,
      "waivable" => "No tips or loans this period"
    )
  end

  it "rejects invalid on date parameters" do
    company = create(:company, payroll_intake_source_types: [ "mosa_revel" ])
    staff = create(:user, company: company, role: "admin")
    stub_portal_user(Api::V1::Admin::CompaniesController, staff, company)

    get "/api/v1/admin/companies/#{company.id}/intake_profile", params: { on: "not-a-date" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("YYYY-MM-DD")
  end

  it "enforces company access and X-Company-Id matching on the admin endpoint" do
    company = create(:company, payroll_intake_source_types: [ "mosa_revel" ])
    other_company = create(:company, payroll_intake_source_types: [ "spike_email" ])
    staff = create(:user, company: company, role: "accountant")
    CompanyAssignment.create!(user: staff, company: company)
    stub_portal_user(Api::V1::Admin::CompaniesController, staff, company)

    get "/api/v1/admin/companies/#{other_company.id}/intake_profile"
    expect(response).to have_http_status(:forbidden)

    get "/api/v1/admin/companies/#{company.id}/intake_profile", headers: { "X-Company-Id" => other_company.id.to_s }
    expect(response).to have_http_status(:forbidden)

    get "/api/v1/admin/companies/999999999/intake_profile"
    expect(response).to have_http_status(:not_found)
  end

  it "exposes a client-scoped intake_profile endpoint for the current client company" do
    company = create(:company, payroll_intake_source_types: [ "mosa_revel" ])
    client = create(:user, company: company, role: "client")
    CompanyAssignment.create!(user: client, company: company)
    stub_portal_user(Api::V1::Client::IntakeProfilesController, client, company)

    get "/api/v1/client/intake_profile"

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("company_id")).to eq(company.id)
    expect(body.fetch("adapters").pluck("key")).to eq([ "mosa_revel" ])
    expect(body.dig("adapters", 0, "portal", "submittable")).to be(true)
    expect(body.dig("adapters", 0)).not_to have_key("parser_version")
    expect(body.dig("adapters", 0)).not_to have_key("idempotency")

    staff = create(:user, company: company, role: "admin")
    stub_portal_user(Api::V1::Client::IntakeProfilesController, staff, company)
    get "/api/v1/client/intake_profile"
    expect(response).to have_http_status(:forbidden)
  end

  it "batches operating-profile lookups in GET /api/v1/companies and omits descriptor internals for client users (L3)" do
    organization = create(:organization)
    c1 = create(:company, organization: organization, payroll_intake_source_types: [ "mosa_revel" ])
    c2 = create(:company, organization: organization, payroll_intake_source_types: [ "spike_email" ])
    client = create(:user, organization: organization, company: c1, role: "client")
    CompanyAssignment.create!(user: client, company: c1)
    CompanyAssignment.create!(user: client, company: c2)
    stub_portal_user(Api::V1::CompaniesController, client, c1)

    profile_queries = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      profile_queries += 1 if sql.include?("client_operating_profiles") && !sql.start_with?("EXPLAIN")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/api/v1/companies"
    end

    expect(response).to have_http_status(:ok)
    expect(profile_queries).to be <= 1
    adapters = response.parsed_body.fetch("companies").flat_map { |row| row.fetch("payroll_intake_adapters") }
    expect(adapters).not_to be_empty
    adapters.each do |adapter|
      expect(adapter).not_to have_key("parser_version")
      expect(adapter).not_to have_key("idempotency")
    end
  end
end
