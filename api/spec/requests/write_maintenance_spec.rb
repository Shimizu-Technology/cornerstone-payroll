# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Write maintenance", type: :request do
  let!(:admin) { create(:user) }
  let(:departments_path) { "/api/v1/admin/departments" }
  let(:department_params) { { department: { name: "Operations" } } }
  let(:origin) { { "Origin" => "http://localhost:5173" } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return("true")
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE_MESSAGE").and_return(nil)
  end

  it "blocks a valid write before database or controller side effects and keeps the CORS headers" do
    expect do
      post departments_path, params: department_params, headers: origin, as: :json
    end.not_to change(Department, :count)

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(response.headers["Access-Control-Allow-Origin"]).to eq(origin.fetch("Origin"))
    expect(response.headers["Access-Control-Expose-Headers"]).to include("Retry-After")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.parsed_body).to eq("code" => "write_maintenance", "error" => WriteMaintenance::DEFAULT_MESSAGE)
  end

  [ " TRUE ", " 1 ", " YeS ", " ON " ].each do |value|
    it "enables maintenance for #{value.inspect}" do
      allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return(value)
      post departments_path, params: department_params, as: :json
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  it "logs the effective state when building the middleware" do
    expect(Rails.logger).to receive(:info).with("[WriteMaintenance] enabled=true")
    WriteMaintenance.new(->(_) { nil })
  end

  it "correlates a rejection without logging a signed upload path" do
    allow(Rails.logger).to receive(:info).and_call_original
    put "/rails/active_storage/disk/private-upload-token", headers: { "X-Request-Id" => "maintenance-probe" }

    expect(response.headers["X-Request-Id"]).to eq("maintenance-probe")
    expect(Rails.logger).to have_received(:info).with("[maintenance-probe] [WriteMaintenance] Blocked PUT request (503)")
    expect(Rails.logger).not_to have_received(:info).with(/private-upload-token/)
  end

  %w[transmittal_log_pdf full_print_package_pdf check_signoff_sheet].each do |report|
    it "blocks GET and HEAD for #{report}, including formatted URLs" do
      path = "/api/v1/admin/reports/#{report}.pdf"

      expect do
        get path
        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["code"]).to eq("write_maintenance")
        expect(response.headers["Retry-After"]).to eq("60")
        head path
        expect(response).to have_http_status(:service_unavailable)
      end.not_to change { [ Transmittal.count, CheckSignoffSheet.count ] }
    end
  end

  %w[/rails/action_mailbox/relay/inbound_emails /rails/conductor/action_mailbox/inbound_emails].each do |path|
    it "blocks mailbox ingress at #{path}" do
      post path
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  it "asks AIRE to retry later before accepting a cutoff change" do
    post "/api/v1/integrations/time_payroll/calendar_periods/123/cutoff_change"
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["code"]).to eq("write_maintenance")
  end

  it "allows the same write when the flag is unset" do
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return(nil)

    expect { post departments_path, params: department_params, as: :json }.to change(Department, :count).by(1)
    expect(response).to have_http_status(:created)
  end

  it "leaves the switch off when set to false" do
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return("false")

    post departments_path, params: department_params, as: :json
    expect(response).to have_http_status(:created)
  end

  it "picks up flag and message changes between requests" do
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE_MESSAGE").and_return("Changes resume after reconciliation.")

    post departments_path, params: department_params, as: :json
    expect(response.parsed_body["error"]).to eq("Changes resume after reconciliation.")

    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return("false")
    post departments_path, params: department_params, as: :json
    expect(response).to have_http_status(:created)
  end

  it "serves public branding and includes tenant CORS on blocked writes to employee paths" do
    company = create(:company, subdomain_slug: "maintenance-demo")
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service",
      hours_source: "manual", options: { subdomain_enabled: true }
    )
    tenant_origin = "https://maintenance-demo.shimizu-technology.com"
    headers = { "Origin" => tenant_origin }

    get "/api/v1/public/tenant_branding", params: { slug: company.subdomain_slug }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Access-Control-Allow-Origin"]).to eq(tenant_origin)
    expect(response.headers["Access-Control-Allow-Credentials"]).to be_nil

    patch "/api/v1/employee/context", headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Access-Control-Allow-Origin"]).to eq(tenant_origin)
    expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
    expect(response.headers["Retry-After"]).to eq("60")
  end

  it "allows GET, HEAD, CORS preflight, and the boot health check" do
    get departments_path
    expect(response).to have_http_status(:ok)

    head departments_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to be_empty

    options departments_path, headers: origin.merge("Access-Control-Request-Method" => "POST")
    expect(response).to have_http_status(:ok)
    expect(response.headers["Access-Control-Allow-Methods"]).to include("POST")

    get "/up"
    expect(response).to have_http_status(:ok)
  end

  {
    put: "/api/v1/admin/departments/1",
    patch: "/api/v1/employee/context",
    delete: "/api/v1/client/documents/1",
    post: "/api/v1/finance/invoices"
  }.each do |method, path|
    it "blocks #{method.upcase} #{path}" do
      public_send(method, path)
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["code"]).to eq("write_maintenance")
    end
  end

  it "blocks both app uploads and Active Storage direct uploads" do
    post "/api/v1/client/documents", params: { file: Rack::Test::UploadedFile.new(__FILE__, "text/plain") }
    expect(response).to have_http_status(:service_unavailable)

    post "/rails/active_storage/direct_uploads"
    expect(response).to have_http_status(:service_unavailable)

    put "/rails/active_storage/disk/signed-upload-token"
    expect(response).to have_http_status(:service_unavailable)
  end

  it "blocks paths normalized by Rails" do
    post "/api//v1/admin/departments", params: department_params, as: :json

    expect(response).to have_http_status(:service_unavailable)
  end
end
