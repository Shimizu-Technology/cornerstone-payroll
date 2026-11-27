# frozen_string_literal: true

require "rails_helper"

# GET /employee/job ("My job") with real Clerk token verification and the RLS
# guard in raise mode. All names are fictional.
RSpec.describe "Employee job", type: :request do
  include EmployeeLinkHelpers

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Alpha Grill") }
  let(:department) { create(:department, company: company, name: "Front of House") }
  let(:employee) do
    create(:employee, company: company, first_name: "Jordan", last_name: "Reyes", email: nil, department: department,
      job_title: "Server", hire_date: Date.new(2024, 3, 4), pay_frequency: "biweekly", pay_rate: 15,
      payment_delivery_method: "direct_deposit", ssn_encrypted: "100-70-4321",
      bank_account_number_encrypted: "998877665544", bank_routing_number_encrypted: "121000358")
  end
  let(:worker) { create(:user, role: :portal_employee, company: company, clerk_id: "user_jordan") }
  let!(:link) { EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active") }

  before { enable_employee_app!(company) }

  def job_for(target_link = link, subject: "user_jordan")
    get "/api/v1/employee/job", headers: bearer(subject).merge("X-Employee-Link-Id" => target_link.id.to_s)
    expect(response).to have_http_status(:ok), response.body
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body.fetch("job")
  end

  it "returns the employee's own job, pay and pay setup as of today" do
    create(:employee_wage_rate, employee: employee, label: "Server", rate: 15, is_primary: true)
    create(:employee_wage_rate, employee: employee, label: "Bartender", rate: 17.5)
    create(:employee_wage_rate, employee: employee, label: "Retired job", rate: 30, active: false)
    CompanyHelpContact.create!(company: company, position: 2, name: "Sam Cruz", phone: "671-555-0101")
    CompanyHelpContact.create!(company: company, position: 1, name: "Alex Santos", phone: "671-555-0100")

    expect(job_for).to eq(
      "employer_name" => "Alpha Grill", "department" => "Front of House", "role" => "Server",
      "employee_id" => employee.id.to_s, "worker_type" => "w2", "pay_frequency" => "biweekly",
      "pay" => { "type" => "hourly", "rates" => [
        { "label" => "Server", "rate" => "15.00" }, { "label" => "Bartender", "rate" => "17.50" }
      ] },
      "start_date" => "2024-03-04", "payment_method" => "direct_deposit", "contact_name" => "Alex Santos"
    )
  end

  it "prefers the company job role over the free-text title and leaves out what isn't set" do
    role = CompanyJobRole.create!(company: company, name: "Line Cook")
    employee.update!(company_job_role: role)
    expect(job_for).to include("role" => "Line Cook")

    employee.update_columns(company_job_role_id: nil, job_title: " ", department_id: nil, hire_date: nil,
      payment_delivery_method: nil)
    expect(job_for).to include("role" => nil, "department" => nil, "start_date" => nil, "payment_method" => nil,
      "contact_name" => nil, "pay" => { "type" => "hourly", "rates" => [ { "label" => nil, "rate" => "15.00" } ] })
  end

  # Pay history is recorded when the worker is set up, so each pay basis gets its own worker.
  def job_of(**attributes)
    clerk_id = "user_#{SecureRandom.hex(4)}"
    login = create(:user, role: :portal_employee, company: company, clerk_id: clerk_id)
    person = create(:employee, company: company, **attributes)
    job_for(EmployeeAccountLink.create!(user: login, company: company, employee: person, status: "active"), subject: clerk_id)
  end

  it "gives a salary per pay period and per year" do
    expect(job_of(employment_type: "salary", salary_type: "annual", pay_rate: 52_000).fetch("pay"))
      .to eq("type" => "salary", "per_period" => "2000.00", "annual" => "52000.00")
    expect(job_of(employment_type: "salary", salary_type: "per_period", pay_rate: 1_500, pay_frequency: "semimonthly"))
      .to include("pay_frequency" => "semimonthly", "pay" => { "type" => "salary", "per_period" => "1500.00", "annual" => "36000.00" })
    expect(job_of(employment_type: "salary", salary_type: "variable", pay_rate: 0).fetch("pay"))
      .to eq("type" => "salary", "per_period" => nil, "annual" => nil)
  end

  it "describes a contractor's flat fee or hourly rate" do
    expect(job_of(employment_type: "contractor", contractor_type: "individual", contractor_pay_type: "flat_fee", pay_rate: 800))
      .to include("worker_type" => "1099", "pay" => { "type" => "flat_fee", "per_period" => "800.00" })
    expect(job_of(employment_type: "contractor", contractor_type: "individual", contractor_pay_type: "hourly", pay_rate: 40).fetch("pay"))
      .to eq("type" => "hourly", "rates" => [ { "label" => nil, "rate" => "40.00" } ])
  end

  it "reads pay from the rate history in effect today, not a cached column" do
    employee.update_columns(pay_rate: 99)
    expect(job_for.fetch("pay")).to eq("type" => "hourly", "rates" => [ { "label" => nil, "rate" => "15.00" } ])
  end

  it "never includes the SSN, bank numbers or internal notes" do
    create(:employee_note, employee: employee, body: "Internal fixture note about pay")
    job_for
    expect(response.body).not_to include("4321", "998877665544", "121000358", "Internal fixture note")
    expect(response.parsed_body.fetch("job").keys).not_to include("ssn", "bank_account_number", "notes")
  end

  it "shows nothing for a former job" do
    link.update!(status: "former", former_at: Time.current,
      former_access_until: (PayrollBusinessClock.today + 700).in_time_zone(PayrollBusinessClock::TIME_ZONE).end_of_day)
    expect(job_for).to be_nil
  end

  it "is a bare 404 for another person's link, or without a link" do
    other_user = create(:user, role: :portal_employee, company: company, clerk_id: "user_other")
    others = EmployeeAccountLink.create!(user: other_user, company: company,
      employee: create(:employee, company: company, job_title: "Manager"), status: "active")
    get "/api/v1/employee/job", headers: bearer("user_jordan").merge("X-Employee-Link-Id" => others.id.to_s)
    expect([ response.status, response.body ]).to eq([ 404, "" ])

    get "/api/v1/employee/job", headers: bearer("user_jordan")
    expect([ response.status, response.body ]).to eq([ 404, "" ])
  end

  it "answers for the employer the app has open when the person works for two" do
    bravo = create(:company, organization: organization, name: "Bravo Cafe")
    enable_employee_app!(bravo)
    bravo_employee = create(:employee, company: bravo, first_name: "Jordan", last_name: "Reyes", job_title: "Barista",
      pay_rate: 13)
    bravo_link = EmployeeAccountLink.create!(user: worker, company: bravo, employee: bravo_employee, status: "active")

    expect(job_for(bravo_link)).to include("employer_name" => "Bravo Cafe", "role" => "Barista",
      "employee_id" => bravo_employee.id.to_s, "pay" => { "type" => "hourly", "rates" => [ { "label" => nil, "rate" => "13.00" } ] })
    expect(job_for(link)).to include("employer_name" => "Alpha Grill", "role" => "Server")
  end

  describe "a demo company" do
    let(:company) { create_demo_company(organization: organization, subdomain_slug: "harborfinch") }
    let(:demo_origin) { "https://harborfinch.#{TenantSubdomainRegistry::DEFAULT_ROOT_DOMAIN}" }
    let(:worker) do
      create(:user, role: :portal_employee, company: company, organization: organization, clerk_id: "user_jordan",
        email: "reviewer+jordan@demo-mail.example")
    end
    # A demo company holds no bank details.
    let(:employee) { create(:employee, company: company, job_title: "Server") }

    around do |example|
      saved = ENV[DemoOutbound::ENV_KEY]
      ENV[DemoOutbound::ENV_KEY] = "reviewer+jordan@demo-mail.example"
      example.run
    ensure
      ENV[DemoOutbound::ENV_KEY] = saved
    end

    before do
      company.client_operating_profiles.sole.update!(options: { subdomain_enabled: true })
      allow(EmployeeAppSwitch::Enforcement).to receive(:demo_open?).and_return(true)
      allow(EmployeeAppSwitch::Enforcement).to receive(:verified?).and_return(false)
      allow(EmployeeAppSwitch::Enforcement).to receive(:waiver_state?).and_return(true)
    end

    it "is refused unless this process runs the RLS guard, and only from the demo's own subdomain" do
      headers = bearer("user_jordan", azp: demo_origin).merge("X-Employee-Link-Id" => link.id.to_s, "Origin" => demo_origin)
      allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(false)
      get "/api/v1/employee/job", headers: headers
      expect([ response.status, response.body ]).to eq([ 404, "" ])

      allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
      get "/api/v1/employee/job", headers: headers.merge("Origin" => EmployeeLinkHelpers::PAYROLL_ORIGIN)
      expect(response).to have_http_status(:not_found)

      get "/api/v1/employee/job", headers: headers
      expect(response).to have_http_status(:ok), response.body
    end
  end

  describe "a view-only support session" do
    let(:company) { create(:company, organization: organization, name: "Alpha Grill", subdomain_slug: "example-fixture") }
    let!(:staff) { create(:user, company: company, role: :super_admin, view_as_allowed: true, clerk_id: "user_support") }
    let(:employee_origin) { "https://example-fixture.shimizu-technology.com" }

    around do |example|
      saved = ENV["REQUIRE_MFA"]
      ENV["REQUIRE_MFA"] = "true"
      example.run
    ensure
      ENV["REQUIRE_MFA"] = saved
    end

    before do
      company.client_operating_profiles.sole.update!(options: { subdomain_enabled: true })
    end

    it "reads the job without changing anything" do
      staff_headers = bearer("user_support", fva: [ 1, 1 ], two_factor_enabled: true)
      post "/api/v1/auth/view_as", params: { target_type: "employee", target_id: employee.id, reason: "Check a display question" },
        as: :json, headers: staff_headers.merge("X-Company-Id" => company.id.to_s)
      expect(response).to have_http_status(:created), response.body
      headers = bearer("user_support", azp: employee_origin, fva: [ 1, 1 ], two_factor_enabled: true)
        .merge(ViewAsGrant::HEADER => response.parsed_body.fetch("token"))

      expect { get "/api/v1/employee/job", headers: headers }.not_to change(Employee, :count)
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("job")).to include("employer_name" => "Alpha Grill", "role" => "Server")
      expect(AuditLog.where(view_as_grant_id: ViewAsGrant.last.id).pluck(:action)).to include("employee_portal/job#show")
    end
  end
end
