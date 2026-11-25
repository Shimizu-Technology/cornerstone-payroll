# frozen_string_literal: true

require "rails_helper"

# M4-9d: a demo company served under the early-access waiver (database RLS
# not enforced yet) answers employee portal requests only while the current
# process runs the RLS guard in raise mode as the restricted role, and only
# to a session (and browser origin) from the demo's own subdomain.
RSpec.describe "Employee portal demo guard", type: :request do
  include EmployeeLinkHelpers

  let(:organization) { create(:organization) }
  let(:company) { create_demo_company(organization: organization, subdomain_slug: "harborfinch") }
  let(:employee) { create(:employee, company: company, first_name: "Jordan", last_name: "Reyes") }
  let(:worker) do
    create(:user, role: :portal_employee, company: company, organization: organization, clerk_id: "user_jordan",
      email: "reviewer+jordan@demo-mail.example")
  end
  let!(:link) { EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active") }
  let(:demo_origin) { "https://harborfinch.#{TenantSubdomainRegistry::ROOT_DOMAIN}" }
  let(:shared_origin) { EmployeeLinkHelpers::PAYROLL_ORIGIN }

  around do |example|
    saved = ENV[DemoOutbound::ENV_KEY]
    ENV[DemoOutbound::ENV_KEY] = "reviewer+jordan@demo-mail.example"
    example.run
  ensure
    ENV[DemoOutbound::ENV_KEY] = saved
  end

  before do
    enable_employee_app!(company, subdomain: true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:demo_open?).and_return(true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:verified?).and_return(false)
    allow(EmployeeAppSwitch::Enforcement).to receive(:waiver_state?).and_return(true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
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

  it "neither lists nor counts a demo link when the browser's Origin isn't its own subdomain" do
    links = ->(origin) do
      headers = bearer("user_jordan", azp: demo_origin)
      headers["Origin"] = origin if origin
      get "/api/v1/employee/links", headers: headers
      expect(response).to have_http_status(:ok), response.body
      response.parsed_body["links"].map { |row| row["id"] }
    end
    count = ->(origin) do
      headers = bearer("user_jordan", azp: demo_origin)
      headers["Origin"] = origin if origin
      get "/api/v1/auth/me", headers: headers
      expect(response).to have_http_status(:ok), response.body
      response.parsed_body.dig("roles", "employee_links_count")
    end

    expect(links.call(shared_origin)).to eq([])
    expect(count.call(shared_origin)).to eq(0)
    expect(EmployeeLinks.openable_links(worker, azp: demo_origin, origin: shared_origin)).to be_empty

    expect(links.call(demo_origin)).to eq([ link.id ])
    expect(count.call(demo_origin)).to eq(1)
    expect(links.call(nil)).to eq([ link.id ])
    expect(count.call(nil)).to eq(1)
  end
end
