# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Employee app status report", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Example Noodle House") }
  let(:other_company) { create(:company, organization: company.organization, name: "Example Juice Bar") }
  let(:staff) { create(:user, company: company, role: :admin, clerk_id: "user_status_staff") }
  let(:manager) { client_login("user_status_manager", company) }
  let(:viewer) { client_login("user_status_viewer", company, access_level: "viewer") }
  let(:outsider) { client_login("user_status_outsider", other_company) }
  let(:kitchen) { Department.create!(company: company, name: "Kitchen") }
  let!(:terms) do
    EmployeeTermsVersion.create!(version: "terms-2026-11", status: "approved", terms_url: "/terms", privacy_url: "/privacy",
      published_at: Time.iso8601("2026-11-20T00:00:00Z"))
  end

  def client_login(clerk_id, target, access_level: "manager")
    create(:user, company: target, role: :client, clerk_id: clerk_id, client_access_level: access_level).tap do |user|
      CompanyAssignment.create!(user: user, company: target)
    end
  end

  def path(actor, suffix = "", target: company)
    "/api/v1/#{actor.client? ? 'client' : 'admin'}/employee_app_status/#{target.id}#{suffix}"
  end

  def headers(actor)
    bearer(actor.clerk_id).merge("X-Company-Id" => actor.company.id.to_s)
  end

  def data
    response.parsed_body.fetch("data")
  end

  def row_for(employee)
    data.fetch("employees").find { |row| row["id"] == employee.id }
  end

  def link!(employee, status:, user: nil, **attributes)
    EmployeeAccountLink.create!(company: company, employee: employee, user: user, status: status,
      last_invited_at: Time.iso8601("2026-11-01T00:00:00Z"), **attributes)
  end

  def employee_login(clerk_id, active: true)
    create(:user, company: company, role: "portal_employee", clerk_id: clerk_id, active: active)
  end

  # Fictional people, one per account state.
  let!(:signed_up) { create(:employee, company: company, first_name: "Ana", last_name: "Sample", department: kitchen, job_title: "Cook") }
  let!(:expired) { create(:employee, company: company, first_name: "Ben", last_name: "Example", department: nil, job_title: "Server") }
  let!(:uninvited) { create(:employee, company: company, first_name: "Cy", last_name: "Placeholder", department: nil, job_title: "Server") }
  let!(:deactivated) { create(:employee, company: company, first_name: "Di", last_name: "Testcase", department: nil, job_title: nil) }
  let!(:former) do
    create(:employee, company: company, first_name: "Ed", last_name: "Gone", department: nil, status: "terminated", termination_date: Date.new(2026, 10, 1))
  end
  let!(:elsewhere) { create(:employee, company: other_company, first_name: "Fay", last_name: "Elsewhere") }

  let(:now) { Time.iso8601("2026-11-27T02:00:00Z") }
  let(:ana_link) do
    link!(signed_up, status: "active", user: employee_login("user_status_ana"), activated_at: Time.iso8601("2026-11-05T00:00:00Z"))
  end

  before do
    enable_employee_app!(company)
    travel_to(now)
    disclosure_seeds

    # Ana: signed up with the current terms, opened the app, paperless stubs, paper W-2GU.
    EmployeeLinks.audit!(ana_link, "claimed", user: ana_link.user, metadata: { terms_version: terms.version })
    AuditLog.record!(user: ana_link.user, organization_id: company.organization_id, company_id: company.id,
      action: "employee_portal/context#show", record_type: "employee_account_links", record_id: ana_link.id,
      ip_address: "203.0.113.77", user_agent: "SecretPhone/9.9")
    AuditLog.where(action: "employee_portal/context#show").update_all(created_at: Time.iso8601("2026-11-26T03:00:00Z"))
    disclosure = DeliveryDisclosure.current_for("pay_statements")
    DeliveryConsent.create!(company: company, user: ana_link.user, employee: signed_up, employee_account_link: ana_link,
      delivery_disclosure: disclosure, kind: "pay_statements", disclosure_version: disclosure.version,
      disclosure_digest: disclosure.digest, given_at: Time.iso8601("2026-11-06T00:00:00Z"), method: "employee_portal_checkbox",
      ip_address: "203.0.113.78", user_agent: "SecretPhone/9.9")
    DeliveryPreference.create!(company: company, employee: signed_up, employee_account_link: ana_link, user: ana_link.user,
      kind: "w2gu", recorded_at: Time.iso8601("2026-11-07T00:00:00Z"), ip_address: "203.0.113.79", user_agent: "SecretPhone/9.9")

    # Ben: an invite that ran out. Di: signed up, then the login was turned off (older terms).
    link!(expired, status: "invited", invite_expires_at: Time.iso8601("2026-11-20T00:00:00Z"))
    di_link = link!(deactivated, status: "active", user: employee_login("user_status_di", active: false),
      activated_at: Time.iso8601("2026-10-01T00:00:00Z"))
    EmployeeLinks.audit!(di_link, "sign_up_started", actor: AuditActor.employee(deactivated), metadata: { terms_version: "terms-2026-10" })
  end

  def disclosure_seeds
    DeliveryDisclosures::DraftSeeds.seed!
  end

  it "shows each active employee's account, terms and paperless answers to staff, with counts for the company" do
    get path(staff), headers: headers(staff)
    expect(response).to have_http_status(:ok), response.body
    expect(response.headers["Cache-Control"]).to include("no-store")

    expect(data.fetch("employees").map { |row| row["name"] }).to eq([ "Ben Example", "Cy Placeholder", "Ana Sample", "Di Testcase" ])
    # Di signed up once, but her login is turned off: not signed up now.
    expect(data["summary"]).to eq(
      "total" => 4, "signed_up" => 1, "opened" => 1, "not_signed_up" => 3, "signed_up_no_opens" => 0,
      "invite_expired" => 1, "terms_not_accepted" => 3, "no_paperless_answer" => 3, "kept_paper" => 1
    )
    expect(data).to include("enabled" => true, "current_terms_version" => "terms-2026-11", "opens_recorded_since" => "2026-11-25")
    expect(data["departments"]).to eq([ { "id" => kitchen.id, "name" => "Kitchen" } ])
    expect(data["roles"]).to eq(%w[Cook Server])

    expect(row_for(signed_up)).to include(
      "department" => { "id" => kitchen.id, "name" => "Kitchen" }, "role" => "Cook",
      "terms" => { "version" => "terms-2026-11", "accepted_at" => "2026-11-27T02:00:00Z", "current" => true },
      "pay_statements" => { "answer" => "paperless", "answered_at" => "2026-11-06T00:00:00Z" },
      "w2gu" => { "answer" => "keep_paper", "answered_at" => "2026-11-07T00:00:00Z" }
    )
    expect(row_for(signed_up)["account"]).to include("status" => "active", "label" => "Signed up", "signed_up" => true,
      "signed_up_at" => "2026-11-05T00:00:00Z", "last_opened_at" => "2026-11-26T03:00:00Z")
    expect(row_for(expired)["account"]).to include("status" => "invite_expired", "label" => "Invite expired",
      "invite_sent_at" => "2026-11-01T00:00:00Z", "invite_expired" => true, "signed_up_at" => nil)
    expect(row_for(uninvited)["account"]).to include("status" => "not_invited", "invite_sent_at" => nil)
    expect(row_for(deactivated)["account"]).to include("status" => "deactivated", "label" => "Deactivated",
      "signed_up" => false, "signed_up_at" => nil)
    expect(row_for(deactivated)["terms"]).to include("version" => "terms-2026-10", "current" => false)
    expect(row_for(uninvited)["terms"]).to eq("version" => nil, "accepted_at" => nil, "current" => false)

    # Statuses and dates only: never consent IP addresses or devices, SSNs or birth dates.
    expect(response.body).not_to include("203.0.113", "SecretPhone", "ssn", "date_of_birth", "user_agent", "ip_address")
  end

  it "narrows rows by each filter chip, department, role and name, while counts stay company-wide" do
    {
      "not_signed_up" => [ expired, uninvited, deactivated ],
      "signed_up_no_opens" => [],
      "invite_expired" => [ expired ],
      "terms_not_accepted" => [ expired, uninvited, deactivated ],
      "no_paperless_answer" => [ expired, uninvited, deactivated ],
      "kept_paper" => [ signed_up ]
    }.each do |filter, expected|
      get path(staff), headers: headers(staff), params: { filter: filter }
      expect(data["employees"].map { |row| row["id"] }).to match_array(expected.map(&:id)), filter
      expect(data.dig("summary", "total")).to eq(4)
    end

    get path(staff), headers: headers(staff), params: { department_id: kitchen.id.to_s }
    expect(data["employees"].map { |row| row["id"] }).to eq([ signed_up.id ])
    get path(staff), headers: headers(staff), params: { role: "Server", filter: "not_signed_up" }
    expect(data["employees"].map { |row| row["id"] }).to eq([ expired.id, uninvited.id ])
    get path(staff), headers: headers(staff), params: { q: "  placeHOLDER " }
    expect(data["employees"].map { |row| row["id"] }).to eq([ uninvited.id ])
    get path(staff), headers: headers(staff), params: { filter: "not_a_filter" }
    expect(data["employees"].size).to eq(4)
  end

  it "exports the filtered rows as CSV and XLSX with dates in Guam days" do
    get path(staff, "/csv"), headers: headers(staff), params: { filter: "kept_paper" }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to include("text/csv")
    expect(response.headers["Content-Disposition"]).to include("example-noodle-house-employee-app-status-2026-11-27.csv")
    rows = CSV.parse(response.body)
    expect(rows.first).to eq(EmployeeAppStatusReport::HEADERS)
    expect(rows.first).to eq([
      "Employee", "Department", "Role", "App account", "Invite sent", "Invite expires", "Signed up", "Last recorded app open",
      "Terms version", "Terms accepted", "Pay stubs", "Pay stubs answered", "W-2GU", "W-2GU answered"
    ])
    expect(rows.drop(1)).to eq([ [
      "Ana Sample", "Kitchen", "Cook", "Signed up", "2026-11-01", nil, "2026-11-05", "2026-11-26",
      "terms-2026-11", "2026-11-27", "Paperless", "2026-11-06", "Keep paper", "2026-11-07"
    ] ])

    get path(manager, "/xlsx"), headers: headers(manager)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to eq(SpreadsheetReportExporter::CONTENT_TYPE)
    expect(response.body.byteslice(0, 2)).to eq("PK")
    expect(response.headers["Content-Disposition"]).to include("employee-app-status-2026-11-27.xlsx")
  end

  it "neutralizes formula-like names in the CSV export" do
    uninvited.update!(first_name: "=HYPERLINK(\"x\")", last_name: "Sample")
    get path(staff, "/csv"), headers: headers(staff), params: { filter: "not_signed_up" }
    expect(CSV.parse(response.body).drop(1).map(&:first)).to include("'=HYPERLINK(\"x\") Sample")
  end

  it "lets client managers and viewers read their own company's report and exports" do
    [ manager, viewer ].each do |actor|
      get path(actor), headers: headers(actor)
      expect(response).to have_http_status(:ok), "#{actor.client_access_level}: #{response.body}"
      expect(data["employees"].map { |row| row["id"] }).not_to include(elsewhere.id, former.id)
      expect(response.body).not_to include("203.0.113", "SecretPhone")
      get path(actor, "/csv"), headers: headers(actor)
      expect(response).to have_http_status(:ok)
    end
  end

  it "refuses another company's report to clients and to a mismatched company context" do
    [ "", "/csv", "/xlsx" ].each do |suffix|
      get path(outsider, suffix), headers: headers(outsider)
      expect(response).to have_http_status(:not_found), suffix
      expect(response.body).not_to include("Ana Sample")
    end
    # Staff looking at one company never get another through the path.
    get path(staff, target: other_company), headers: headers(staff)
    expect(response).to have_http_status(:not_found)
  end

  it "adds the same facts to the employee profile panel on both sides, and keeps viewers read-only" do
    [ staff, manager, viewer ].each do |actor|
      get "/api/v1/#{actor.client? ? 'client' : 'admin'}/employees/#{signed_up.id}/employee_app", headers: headers(actor)
      expect(response).to have_http_status(:ok), response.body
      expect(data["agreements"]).to include(
        "current_terms_version" => "terms-2026-11",
        "terms" => { "version" => "terms-2026-11", "accepted_at" => "2026-11-27T02:00:00Z", "current" => true },
        "pay_statements" => { "answer" => "paperless", "answered_at" => "2026-11-06T00:00:00Z" },
        "w2gu" => { "answer" => "keep_paper", "answered_at" => "2026-11-07T00:00:00Z" }
      )
      expect(data.dig("agreements", "account")).to include("last_opened_at" => "2026-11-26T03:00:00Z", "signed_up_at" => "2026-11-05T00:00:00Z")
      expect(response.body).not_to include("203.0.113", "SecretPhone")
    end

    # A former employee's profile still shows what they agreed to.
    get "/api/v1/admin/employees/#{former.id}/employee_app", headers: headers(staff)
    expect(data.dig("agreements", "pay_statements", "answer")).to eq("not_answered")

    post "/api/v1/client/employees/#{expired.id}/employee_app/resend", headers: headers(viewer),
      params: { access_id: expired.employee_account_links.last.id, delivery: "email" }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["code"]).to eq("client_view_only")
  end

  def record_open!(link, at)
    AuditLog.record!(user: link.user, organization_id: company.organization_id, company_id: company.id,
      action: "employee_portal/context#show", record_type: "employee_account_links", record_id: link.id)
    latest = AuditLog.where(action: "employee_portal/context#show", user_id: link.user_id).maximum(:id)
    AuditLog.where(id: latest).update_all(created_at: at)
  end

  it "keeps signed up and opened the app separate through resets, rehires and turned-off logins" do
    # Gil's sign-up was reset and a fresh invite went out: re-invited, not signed up.
    reset = create(:employee, company: company, first_name: "Gil", last_name: "Resetcase", department: nil)
    reset_link = link!(reset, status: "invited", invite_expires_at: 3.days.from_now)
    EmployeeLinks.audit!(reset_link, "sign_up_reset", user: staff)
    # Hal was rehired: his old login opened the app, and his new invite is open.
    rehired = create(:employee, company: company, first_name: "Hal", last_name: "Rehire", department: nil)
    old_link = link!(rehired, status: "former", user: employee_login("user_status_hal"),
      activated_at: Time.iso8601("2026-06-01T00:00:00Z"), former_at: 1.month.ago, former_access_until: 1.week.ago)
    record_open!(old_link, Time.iso8601("2026-11-25T05:00:00Z"))
    link!(rehired, status: "invited", invite_expires_at: 3.days.from_now)
    # Ivy signed up and hasn't opened the app since recording began.
    quiet = create(:employee, company: company, first_name: "Ivy", last_name: "Quiet", department: nil)
    link!(quiet, status: "active", user: employee_login("user_status_ivy"), activated_at: Time.iso8601("2026-11-10T00:00:00Z"))

    get path(staff), headers: headers(staff)
    expect(row_for(reset)["account"]).to include("status" => "reinvited", "label" => "Re-invited", "signed_up" => false)
    expect(row_for(rehired)["account"]).to include("status" => "reinvited", "signed_up" => false, "signed_up_at" => nil,
      "last_opened_at" => "2026-11-25T05:00:00Z")
    expect(row_for(quiet)["account"]).to include("status" => "active", "signed_up" => true, "last_opened_at" => nil)
    expect(data["summary"]).to include("total" => 7, "signed_up" => 2, "opened" => 2, "not_signed_up" => 5, "signed_up_no_opens" => 1)

    get path(staff), headers: headers(staff), params: { filter: "signed_up_no_opens" }
    expect(data["employees"].map { |row| row["id"] }).to eq([ quiet.id ])

    # Turning a login off moves the person out of signed up, in the report and the panel alike.
    quiet.employee_account_links.sole.user.update!(active: false)
    get path(staff), headers: headers(staff), params: { filter: "not_signed_up" }
    expect(data["employees"].map { |row| row["id"] }).to include(quiet.id)
    get "/api/v1/admin/employees/#{quiet.id}/employee_app", headers: headers(staff)
    # The panel's invite actions still follow the link (active); what people see is the shared label.
    expect(data).to include("status" => "active")
    expect(data.dig("agreements", "account")).to include("status" => "deactivated", "label" => "Deactivated", "signed_up" => false)
    expect(data.dig("agreements", "opens_recorded_since")).to eq("2026-11-25")
  end

  it "reads each latest fact in a fixed number of queries, using the app-open index, on a history-heavy company" do
    logins = Array.new(12) do |index|
      person = create(:employee, company: company, first_name: "Load#{index}", last_name: "Fixture", department: nil)
      link!(person, status: "active", user: employee_login("user_status_load_#{index}"), activated_at: 1.month.ago)
    end
    base = Time.iso8601("2026-11-25T00:00:00Z")
    rows = logins.flat_map do |link|
      Array.new(400) do |step|
        { company_id: company.id, organization_id: company.organization_id, user_id: link.user_id, action: "employee_portal/context#show",
          record_type: "employee_account_links", record_id: link.id, actor_type: "employee", actor_id: link.employee_id.to_s,
          actor_name: "Fixture", event_category: "employee_portal", metadata: {}, created_at: base + step.minutes }
      end
    end
    AuditLog.insert_all!(rows)
    AuditLog.connection.execute("ANALYZE audit_logs")

    count_queries = lambda do |&block|
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE|SET|SELECT set_config)/i) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      statements
    end
    report = EmployeeAppStatusReport.new(company)
    full = count_queries.call { EmployeeAppStatusReport.new(company).call }
    10.times do |index|
      person = create(:employee, company: company, first_name: "More#{index}", last_name: "Fixture", department: nil)
      link!(person, status: "active", user: employee_login("user_status_more_#{index}"), activated_at: 1.month.ago)
    end
    # Ten more employees, the same statements: nothing runs per employee.
    more = count_queries.call { EmployeeAppStatusReport.new(company).call }
    expect(more.size).to eq(full.size), (more - full).join("\n")

    report.call.fetch(:employees).find { |row| row[:name] == "Load0 Fixture" }.then do |row|
      expect(row.dig(:account, :last_opened_at)).to eq((base + 399.minutes).iso8601)
    end

    opens_sql = full.find { |sql| sql.include?("CROSS JOIN LATERAL") }
    expect(opens_sql).to be_present
    plan = AuditLog.connection.select_values("EXPLAIN #{opens_sql}").join("\n")
    expect(plan).to include("idx_audit_logs_employee_app_opens")
  end

  it "shows W-2GU as not applicable for a 1099 contractor and leaves it out of the paperless chips" do
    contractor = create(:employee, :contractor, company: company, first_name: "Kai", last_name: "Contractor", department: nil)
    get path(staff), headers: headers(staff)
    expect(row_for(contractor)["w2gu"]).to eq("answer" => "not_applicable", "answered_at" => nil)
    expect(row_for(contractor)["pay_statements"]["answer"]).to eq("not_answered")

    kai_link = link!(contractor, status: "active", user: employee_login("user_status_kai"), activated_at: 1.day.ago)
    DeliveryPreference.create!(company: company, employee: contractor, employee_account_link: kai_link, user: kai_link.user,
      kind: "pay_statements", recorded_at: 1.hour.ago)
    get path(staff), headers: headers(staff), params: { filter: "no_paperless_answer" }
    expect(data["employees"].map { |row| row["id"] }).not_to include(contractor.id)
    get path(staff, "/csv"), headers: headers(staff), params: { q: "kai" }
    expect(CSV.parse(response.body).last.values_at(10, 12)).to eq([ "Keep paper", "Not applicable (1099)" ])
  end

  it "computes an export only for the employees its department, role and name filters leave" do
    queried_ids = []
    allow(DeliveryConsents::Answers).to receive(:by_employee).and_wrap_original do |original, company_id, ids|
      queried_ids << ids.to_a
      original.call(company_id, ids)
    end
    get path(staff, "/csv"), headers: headers(staff), params: { q: "sample" }
    expect(CSV.parse(response.body).drop(1).map(&:first)).to eq([ "Ana Sample" ])
    expect(queried_ids).to eq([ [ signed_up.id ] ])
  end
end
