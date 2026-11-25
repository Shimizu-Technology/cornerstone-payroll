# frozen_string_literal: true

require "rails_helper"

# M4-9d: a demo company served under the early-access waiver (database RLS
# not enforced yet) answers employee portal requests only while the current
# process runs the RLS guard in raise mode as the restricted role, and only
# to a session (and browser origin) from the demo's own subdomain.
RSpec.describe "Employee portal demo guard", type: :request do
  include EmployeeLinkHelpers

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Alpha Grill", subdomain_slug: "harborfinch") }
  let(:employee) { create(:employee, company: company, first_name: "Jordan", last_name: "Reyes") }
  let(:worker) { create(:user, role: :portal_employee, company: company, organization: organization, clerk_id: "user_jordan") }
  let!(:link) { EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active") }
  let(:demo_origin) { "https://harborfinch.cornerstone-payroll.example" }
  let(:shared_origin) { EmployeeLinkHelpers::PAYROLL_ORIGIN }

  before do
    enable_employee_app!(company, subdomain: true)
    # Stands in for a demo company until demo employee logins land (PR #585):
    # the request path only asks whether the link's company is a demo.
    allow_any_instance_of(Company).to receive(:demo?).and_return(true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:demo_open?).and_return(true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:verified?).and_return(false)
    allow(EmployeeAppSwitch::Enforcement).to receive(:waiver_state?).and_return(true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
    allow(TenantSubdomainRegistry).to receive(:client_origin?).and_call_original
    allow(TenantSubdomainRegistry).to receive(:client_origin?).with(demo_origin).and_return(true)
    allow(TenantSubdomainRegistry).to receive(:enabled_origin_company_id).and_call_original
    allow(TenantSubdomainRegistry).to receive(:enabled_origin_company_id).with(demo_origin).and_return(company.id)
    allow(TenantSubdomainRegistry).to receive(:allowed_origin?).and_call_original
    allow(TenantSubdomainRegistry).to receive(:allowed_origin?).with(demo_origin).and_return(true)
  end

  def context!(azp: demo_origin, origin: demo_origin)
    headers = bearer("user_jordan", azp: azp).merge("X-Employee-Link-Id" => link.id.to_s)
    headers["Origin"] = origin if origin
    get "/api/v1/employee/context", headers: headers
  end

  it "answers not found unless this process is guarded, and serves normally once it is" do
    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(false)
    context!
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank

    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
    context!
    expect(response).to have_http_status(:ok), response.body
  end

  it "doesn't need the waiver check once the database enforces RLS" do
    allow(EmployeeAppSwitch::Enforcement).to receive(:verified?).and_return(true)
    expect(EmployeeAppSwitch::Enforcement).not_to receive(:current_process_guarded?)
    context!
    expect(response).to have_http_status(:ok), response.body
  end

  it "pins data requests to the demo's own subdomain: session and browser origin" do
    context!(azp: shared_origin, origin: nil)
    expect(response).to have_http_status(:not_found)

    context!(origin: shared_origin)
    expect(response).to have_http_status(:not_found)

    context!(origin: nil)
    expect(response).to have_http_status(:ok), response.body
  end

  it "neither lists nor counts a demo link outside its gate" do
    get "/api/v1/employee/links", headers: bearer("user_jordan", azp: demo_origin)
    expect(response.parsed_body["links"].map { |row| row["id"] }).to eq([ link.id ])

    get "/api/v1/employee/links", headers: bearer("user_jordan", azp: shared_origin)
    expect(response.parsed_body["links"]).to eq([])
    expect(EmployeeLinks.openable_links(worker, azp: shared_origin)).to be_empty

    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(false)
    get "/api/v1/employee/links", headers: bearer("user_jordan", azp: demo_origin)
    expect(response.parsed_body["links"]).to eq([])
    expect(EmployeeLinks.openable_links(worker, azp: demo_origin)).to be_empty
  end
end
