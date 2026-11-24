# frozen_string_literal: true

require "rails_helper"

# Cross-company and cross-link matrix for the employee account routes, with
# real token verification and the RLS guard in raise mode.
RSpec.describe "Employee link isolation", type: :request do
  include EmployeeLinkHelpers

  let(:organization) { create(:organization) }
  let(:alpha) { create(:company, organization: organization, name: "Alpha Grill", subdomain_slug: "alphagrill") }
  let(:bravo) { create(:company, organization: organization, name: "Bravo Cafe", subdomain_slug: "bravocafe") }
  let(:alpha_origin) { "https://alphagrill.shimizu-technology.com" }
  let(:bravo_origin) { "https://bravocafe.shimizu-technology.com" }
  let(:worker) { create(:user, role: :portal_employee, company: alpha, name: "Jordan Reyes", clerk_id: "user_jordan") }
  let(:alpha_link) { create_link(alpha) }
  let(:bravo_link) { create_link(bravo) }

  before do
    enable_employee_app!(alpha, subdomain: true)
    enable_employee_app!(bravo, subdomain: true)
  end

  def create_link(company, user: worker, status: "active", **attributes)
    employee = create(:employee, company: company, first_name: "Jordan", last_name: "Reyes", email: nil,
      date_of_birth: Date.new(1992, 6, 30))
    EmployeeAccountLink.create!(user: user, company: company, employee: employee, status: status, **attributes)
  end

  def link_ids(origin = EmployeeLinkHelpers::PAYROLL_ORIGIN, subject: "user_jordan")
    get "/api/v1/employee/links", headers: bearer(subject, azp: origin)
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("links").map { |link| link.fetch("id") }
  end

  def context_status(link, origin: EmployeeLinkHelpers::PAYROLL_ORIGIN, subject: "user_jordan")
    get "/api/v1/employee/context", headers: bearer(subject, azp: origin).merge("X-Employee-Link-Id" => link.id.to_s)
    response.status
  end

  it "lists every eligible link on the main origin and only the subdomain's company on a client subdomain" do
    [ alpha_link, bravo_link ]
    expect(link_ids).to eq([ alpha_link.id, bravo_link.id ])
    expect(link_ids(alpha_origin)).to eq([ alpha_link.id ])
    expect(link_ids(bravo_origin)).to eq([ bravo_link.id ])
  end

  it "opens a link only on its own company's subdomain or the main origin" do
    expect(context_status(alpha_link, origin: alpha_origin)).to eq(204)
    expect(context_status(bravo_link, origin: alpha_origin)).to eq(404)
    expect(context_status(bravo_link, origin: bravo_origin)).to eq(204)
    expect(context_status(bravo_link)).to eq(204)
  end

  it "hides invited, revoked, expired-former links and companies with the app off, and never another user's link" do
    other = create(:user, role: :portal_employee, company: alpha, clerk_id: "user_other")
    others_link = create_link(alpha, user: other)
    invited = create_link(alpha, user: worker, status: "invited")
    revoked = create_link(alpha, status: "revoked")
    former_open = create_link(bravo, status: "former", former_access_until: 1.year.from_now)
    former_closed = create_link(bravo, status: "former", former_access_until: 1.day.ago)
    off = create(:company, organization: organization)
    off_link = create_link(off)

    expect(link_ids).to eq([ former_open.id ])
    [ others_link, invited, revoked, former_closed, off_link ].each do |link|
      expect(context_status(link)).to eq(404), "link #{link.status} opened"
    end
    expect(context_status(former_open)).to eq(204)
  end

  it "returns the same empty 404 for missing, malformed and unverifiable credentials" do
    alpha_link
    [
      {}, { "X-Employee-Link-Id" => alpha_link.id.to_s },
      { "Authorization" => "Bearer not.a.token", "X-Employee-Link-Id" => alpha_link.id.to_s },
      bearer("user_jordan").merge("X-Employee-Link-Id" => "0"),
      bearer("user_jordan").merge("X-Employee-Link-Id" => "#{alpha_link.id}x"),
      bearer("user_unknown").merge("X-Employee-Link-Id" => alpha_link.id.to_s)
    ].each do |headers|
      get "/api/v1/employee/context", headers: headers
      expect([ response.status, response.body ]).to eq([ 404, "" ])
    end

    [ {}, { "Authorization" => "Bearer not.a.token" }, bearer("user_unknown") ].each do |headers|
      get "/api/v1/employee/links", headers: headers
      expect([ response.status, response.body ]).to eq([ 404, "" ])
    end
    worker.update!(active: false)
    get "/api/v1/employee/links", headers: bearer("user_jordan")
    expect(response).to have_http_status(:not_found)
  end

  it "won't claim another company's invite from a client subdomain" do
    employee = create(:employee, company: bravo, first_name: "Jordan", last_name: "Reyes", email: nil,
      date_of_birth: Date.new(1992, 6, 30))
    staff = create(:user, role: :admin, company: bravo)
    invite = invite!(employee, actor: staff, delivery: "code")
    params = activation_params(employee, code: invite.code).except(:email)
    claim = ->(origin) {
      post "/api/v1/employee/links/claim", params: params.to_json,
        headers: bearer("user_jordan", azp: origin).merge("CONTENT_TYPE" => "application/json")
    }
    worker

    claim.call(alpha_origin)
    expect(response).to have_http_status(:not_found)
    expect(invite.link.reload).to be_invited

    claim.call(bravo_origin)
    expect(response).to have_http_status(:created)
    expect(invite.link.reload).to have_attributes(status: "active", user_id: worker.id)
  end

  it "won't claim into another organization" do
    elsewhere = create(:company, name: "Elsewhere")
    enable_employee_app!(elsewhere)
    employee = create(:employee, company: elsewhere, first_name: "Jordan", last_name: "Reyes", date_of_birth: Date.new(1992, 6, 30))
    invite = invite!(employee, actor: create(:user, role: :admin, company: elsewhere), delivery: "code")
    worker

    post "/api/v1/employee/links/claim", params: activation_params(employee, code: invite.code).to_json,
      headers: bearer("user_jordan").merge("CONTENT_TYPE" => "application/json")

    expect(response).to have_http_status(:not_found)
    expect(invite.link.reload).to be_invited
  end

  it "binds a new sign-up only from its own company's subdomain" do
    employee = create(:employee, company: bravo, email: "casey@example.net", date_of_birth: Date.new(1995, 2, 3))
    invite = invite!(employee, actor: create(:user, role: :admin, company: bravo))
    expect(invite.link.invite_email).to eq("casey@example.net")

    post_activation(activation_params(employee, token: invite.token, email: "casey@example.net"))
    expect(clerk_invitations.sole[:redirect_url]).to eq("#{bravo_origin}/sign-up")
    accept_clerk_invitation!("user_casey")

    get "/api/v1/auth/me", headers: bearer("user_casey", azp: alpha_origin)
    expect(response).to have_http_status(:unauthorized)
    expect(invite.link.reload).to be_invited

    get "/api/v1/auth/me", headers: bearer("user_casey", azp: bravo_origin)
    expect(response).to have_http_status(:ok)
    expect(invite.link.reload).to be_active
  end
end
