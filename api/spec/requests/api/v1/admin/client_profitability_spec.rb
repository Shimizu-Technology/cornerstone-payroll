# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client profitability", type: :request do
  let(:practice) { create(:company, name: "Cornerstone") }
  let(:organization) { practice.organization }
  let!(:acme) { create(:company, organization: organization, name: "Acme Bakery, Inc.") }
  let(:admin) { create(:user, company: practice, role: "admin") }
  let!(:mark) { create(:employee, company: practice, first_name: "Mark", last_name: "Santos", email: "mark@cornerstone.example") }
  let(:current) { admin }
  let(:connected) { TaxWorkHours::Configuration.new(base_url: "https://tax.example.test", secret: "test-secret-value") }
  let(:disconnected) { TaxWorkHours::Configuration.new(base_url: nil, secret: nil) }

  before do
    allow_any_instance_of(Api::V1::Admin::ClientProfitabilityController).to receive(:current_user) { current }
    allow_any_instance_of(Api::V1::Admin::ClientProfitabilityController).to receive(:current_company_id).and_return(practice.id)
    allow(TaxWorkHours::Configuration).to receive(:current).and_return(disconnected)
  end

  def json
    response.parsed_body
  end

  def seed_hours
    import = WorkHourImport.create!(organization: organization, range_start: Date.new(2026, 10, 1), range_end: Date.new(2026, 10, 31),
                                    status: "succeeded", finished_at: Time.current)
    [ [ 12, "mark@cornerstone.example", 345, "Acme Bakery", nil, 5 ], [ 12, "mark@cornerstone.example", 500, "Internal – Cornerstone", "internal", 2 ],
      [ 20, "ky@cornerstone.example", 777, "Zeta Farms", nil, 1 ] ].each do |tax_user_id, email, client_id, name, kind, hours|
      WorkHourRow.create!(organization: organization, work_hour_import: import, tax_user_id: tax_user_id, email: email,
                          work_date: Date.new(2026, 10, 5), tax_client_id: client_id, client_name: name, system_kind: kind,
                          hours: hours, approval_state: "approved", category: "Bookkeeping")
    end
  end

  %w[manager accountant].each do |role|
    it "is closed to #{role}s" do
      user = create(:user, company: practice, role: role)
      CompanyAssignment.create!(user: user, company: practice)
      allow_any_instance_of(Api::V1::Admin::ClientProfitabilityController).to receive(:current_user).and_return(user)
      get "/api/v1/admin/client_profitability"
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/admin/client_profitability/report", params: { from: "2026-10" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "shows a not-connected state without calling Tax or erroring" do
    get "/api/v1/admin/client_profitability"
    expect(response).to have_http_status(:ok)
    expect(json["connection"]).to eq("connected" => false, "missing" => %w[CORNERSTONE_TAX_API_URL PAYROLL_WORK_HOURS_SECRET],
                                     "problem" => nil, "tax_host" => nil)
    expect(json["has_hours"]).to be(false)

    post "/api/v1/admin/client_profitability/refresh", params: { from: "2026-10", through: "2026-10" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["code"]).to eq("not_connected")
    expect(WorkHourImport.count).to eq(0)
  end

  it "saves the practice company, book and tax-prep services, and rejects another organization's client" do
    patch "/api/v1/admin/client_profitability/settings",
          params: { practice_company_id: practice.id, tax_prep_service_names: [ "Tax Preparation", "tax preparation" ] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(json["settings"]).to include("practice_company_id" => practice.id, "tax_prep_service_names" => [ "Tax Preparation" ])

    patch "/api/v1/admin/client_profitability/settings", params: { practice_company_id: create(:company).id }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(AuditLog.where(action: "client_profitability#update_settings").count).to eq(1)
  end

  it "queues a refresh, refuses a second one while it runs, and reports its status" do
    allow(TaxWorkHours::Configuration).to receive(:current).and_return(connected)
    allow(PayrollBusinessClock).to receive(:today).and_return(Date.new(2026, 11, 21))
    allow(TaxWorkHoursImportJob).to receive(:perform_later)
    post "/api/v1/admin/client_profitability/refresh", params: { from: "2026-10", through: "2026-12" }
    expect(response).to have_http_status(:accepted)
    expect(json["import"]).to include("status" => "queued", "range_start" => "2026-10-01", "range_end" => "2026-11-21")
    expect(TaxWorkHoursImportJob).to have_received(:perform_later).with(WorkHourImport.last.id)
    expect(response.body).not_to include("test-secret-value")

    post "/api/v1/admin/client_profitability/refresh", params: { from: "2026-10" }
    expect(response).to have_http_status(:conflict)

    get "/api/v1/admin/client_profitability/imports/#{WorkHourImport.last.id}"
    expect(json.dig("import", "status")).to eq("queued")

    WorkHourImport.update_all(status: "failed")
    post "/api/v1/admin/client_profitability/refresh", params: { from: "2026-12" }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "lists Tax clients and staff with suggestions, and saves, changes and removes links" do
    ClientProfitabilitySetting.create!(organization: organization, practice_company: practice)
    seed_hours
    get "/api/v1/admin/client_profitability/links"
    clients = json["clients"].index_by { |client| client["name"] }
    expect(clients["Acme Bakery"]["suggestion"]).to include("company_id" => acme.id, "match" => "exact")
    expect(clients["Internal – Cornerstone"]).to include("handled_automatically" => true)
    expect(clients["Zeta Farms"]["suggestion"]).to be_nil
    staff = json["staff"].index_by { |person| person["tax_user_id"] }
    expect(staff[12]["suggestion"]).to include("employee_id" => mark.id, "match" => "exact")

    put "/api/v1/admin/client_profitability/client_links/345", params: { disposition: "company", company_id: acme.id, tax_client_name: "Acme Bakery" }
    expect(response).to have_http_status(:ok)
    put "/api/v1/admin/client_profitability/client_links/777", params: { disposition: "company", company_id: create(:company).id }
    expect(response).to have_http_status(:unprocessable_content)
    put "/api/v1/admin/client_profitability/client_links/777", params: { disposition: "internal" }
    expect(WorkHourClientLink.find_by(tax_client_id: 777).disposition).to eq("internal")
    delete "/api/v1/admin/client_profitability/client_links/777"
    expect(response).to have_http_status(:no_content)
    expect(WorkHourClientLink.exists?(tax_client_id: 777)).to be(false)

    other_employee = create(:employee, company: acme)
    put "/api/v1/admin/client_profitability/staff_links/12", params: { disposition: "employee", employee_id: other_employee.id }
    expect(response).to have_http_status(:unprocessable_content)
    put "/api/v1/admin/client_profitability/staff_links/12", params: { disposition: "employee", employee_id: mark.id }
    expect(response).to have_http_status(:ok)
    put "/api/v1/admin/client_profitability/staff_links/20", params: { disposition: "no_payroll" }
    expect(response).to have_http_status(:ok)

    get "/api/v1/admin/client_profitability"
    expect(json["needs_linking"]).to eq("clients" => 1, "staff" => 0)
  end

  it "returns the report and a CSV, keeping unlinked hours visible" do
    ClientProfitabilitySetting.create!(organization: organization, practice_company: practice)
    seed_hours
    WorkHourClientLink.create!(organization: organization, tax_client_id: 345, disposition: "company", company: acme)

    get "/api/v1/admin/client_profitability/report", params: { from: "2026-10", through: "2026-10", spread_overhead: "true" }
    expect(response).to have_http_status(:ok)
    expect(json.dig("options", "spread_overhead")).to be(true)
    expect(json["clients"].map { |client| client["name"] }).to eq([ "Acme Bakery, Inc." ])
    expect(json["unassigned"].map { |line| line["name"] }).to eq([ "Zeta Farms" ])
    expect(json.dig("connection", "connected")).to be(false)

    get "/api/v1/admin/client_profitability/export", params: { from: "2026-10" }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Disposition"]).to include("client-profitability-2026-10.csv")
    csv = CSV.parse(response.body)
    expect(csv[3].first(4)).to eq([ "Section", "Client", "Person", "Hours" ])
    expect(csv.map(&:first)).to include("Client", "Person", "Not linked yet", "Total")
    expect(AuditLog.where(action: "client_profitability#export").count).to eq(1)

    get "/api/v1/admin/client_profitability/report", params: { from: "October" }
    expect(response).to have_http_status(:unprocessable_content)
  end
end
