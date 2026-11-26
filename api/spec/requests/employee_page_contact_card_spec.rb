# frozen_string_literal: true

require "rails_helper"

# The employee page's Contact card saves through the same staff and client
# employee update endpoints as the Contact details grid, with the payload the
# card sends: only changed fields, the row revision and baseline values from
# when Edit was opened, and the contact-only response. These specs pin that
# every PR #619 safeguard still runs on that path.
RSpec.describe "Employee page Contact card", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Example Bakery") }
  let(:staff) { create(:user, role: :admin, company: company, clerk_id: "user_card_staff") }
  let(:manager) { client_login("user_card_manager", access_level: "manager") }
  let(:viewer) { client_login("user_card_viewer", access_level: "viewer") }
  let(:employee) do
    create(:employee, company: company, first_name: "Riley", last_name: "Santos", email: "riley.old@example.net",
      phone: "+16715550100", date_of_birth: Date.new(1990, 4, 12))
  end

  before { enable_employee_app!(company) }

  def client_login(clerk_id, access_level:)
    create(:user, company: company, role: :client, clerk_id: clerk_id, client_access_level: access_level).tap do |user|
      CompanyAssignment.create!(user: user, company: company)
    end
  end

  def card_save(actor, changes, revision: employee.reload.contact_revision, baseline: nil)
    namespace = actor.client? ? "client" : "admin"
    baseline ||= changes.to_h { |field, _| [ field, employee.public_send(field) ] }
    patch "/api/v1/#{namespace}/employees/#{employee.id}",
      params: { employee: changes, row_revision: revision, baseline_values: baseline, response_view: "contact" },
      as: :json, headers: bearer(actor.clerk_id).merge("X-Company-Id" => company.id.to_s)
  end

  def audits(action)
    AuditLog.where(action: action, record_type: "employees", record_id: employee.id)
  end

  { staff: "employees#update", manager: "client_employees#update" }.each do |who, update_action|
    it "changes the email for #{who}: closes the invite, saves the old-address notice and writes both audits" do
      actor = public_send(who)
      invite = invite!(employee, actor: staff)
      generation = invite.link.invite_generation

      expect { card_save(actor, { email: "riley.new@example.net" }) }.to have_enqueued_job(SendEmployeeEmailChangeNoticeJob)
      expect(response).to have_http_status(:ok), response.body

      body = response.parsed_body
      expect(body.dig("data", "email")).to eq("riley.new@example.net")
      expect(body.dig("data", "contact_revision")).to be_present
      # The contact-only response never carries payroll fields.
      expect(body["data"].keys).not_to include("ssn", "pay_rate", "ssn_last_four")

      link = invite.link.reload
      expect(link.invite_open?).to be(false)
      expect(link.invite_generation).to eq(generation + 1)
      expect(EmployeeEmailChangeNotice.where(employee: employee).sole)
        .to have_attributes(recipient_email: "riley.old@example.net", status: "pending")

      expect(audits("employee_links#contact_email_changed").sole).to have_attributes(user_id: actor.id, event_category: "security")
      expect(audits("employee_links#contact_email_changed").sole.metadata)
        .to include("from_email" => "riley.old@example.net", "to_email" => "riley.new@example.net")
      expect(audits(update_action)).to exist
    end

    it "saves a mobile-only edit for #{who} without touching the email or the invite" do
      actor = public_send(who)
      invite = invite!(employee, actor: staff)

      card_save(actor, { phone: "671-555-0199" })
      expect(response).to have_http_status(:ok), response.body
      expect(employee.reload).to have_attributes(phone: "+16715550199", email: "riley.old@example.net")
      expect(invite.link.reload.invite_open?).to be(true)
      expect(audits("employee_links#contact_email_changed")).to be_empty
      expect(EmployeeEmailChangeNotice.where(employee: employee)).to be_empty
    end

    it "reports a coworker's change to the same field for #{who} instead of overwriting it" do
      actor = public_send(who)
      opened_revision = employee.contact_revision
      travel 2.seconds do
        employee.update!(email: "coworker.set@example.net")
      end

      card_save(actor, { email: "riley.new@example.net" }, revision: opened_revision, baseline: { email: "riley.old@example.net" })
      expect(response).to have_http_status(:conflict), response.body
      expect(response.parsed_body).to include("code" => "contact_revision_conflict", "conflicting_fields" => [ "email" ])
      expect(response.parsed_body.dig("data", "email")).to eq("coworker.set@example.net")
      expect(employee.reload.email).to eq("coworker.set@example.net")
      expect(audits("employee_links#contact_email_changed")).to be_empty
    end

    it "merges a non-overlapping edit for #{who} when a coworker changed another field" do
      actor = public_send(who)
      opened_revision = employee.contact_revision
      travel 2.seconds do
        employee.update!(email: "coworker.set@example.net")
      end

      card_save(actor, { phone: "671-555-0199" }, revision: opened_revision, baseline: { phone: "+16715550100" })
      expect(response).to have_http_status(:ok), response.body
      expect(employee.reload).to have_attributes(phone: "+16715550199", email: "coworker.set@example.net")
    end
  end

  %i[staff manager].each do |who|
    it "returns a plain field message for an invalid email (#{who})" do
      card_save(public_send(who), { email: "not-an-email" })
      expect(response).to have_http_status(:unprocessable_content), response.body
      expect(response.parsed_body.dig("details", "email")).to be_present
      expect(response.parsed_body.dig("contact_validation", "email_error_code")).to eq("invalid_email")
      expect(employee.reload.email).to eq("riley.old@example.net")
    end
  end

  it "conflicts again when a third person saves between the conflict and a Keep yours retry" do
    opened_revision = employee.contact_revision
    travel 2.seconds do
      employee.update!(email: "second.person@example.net")
    end
    card_save(manager, { email: "riley.new@example.net" }, revision: opened_revision, baseline: { email: "riley.old@example.net" })
    expect(response).to have_http_status(:conflict), response.body
    # Keep yours resends against the record the conflict returned.
    rebased_revision = response.parsed_body.dig("data", "contact_revision")
    rebased_email = response.parsed_body.dig("data", "email")

    travel 4.seconds do
      employee.update!(email: "third.person@example.net")
    end
    travel 6.seconds do
      card_save(manager, { email: "riley.new@example.net" }, revision: rebased_revision, baseline: { email: rebased_email })
    end
    expect(response).to have_http_status(:conflict), response.body
    expect(response.parsed_body.dig("data", "email")).to eq("third.person@example.net")
    expect(employee.reload.email).to eq("third.person@example.net")

    # Keeping mine against the newest record saves.
    travel 8.seconds do
      card_save(manager, { email: "riley.new@example.net" }, revision: employee.contact_revision, baseline: { email: "third.person@example.net" })
    end
    expect(response).to have_http_status(:ok), response.body
    expect(employee.reload.email).to eq("riley.new@example.net")
  end

  it "refuses a Client viewer's save with a plain 403 and changes nothing" do
    invite = invite!(employee, actor: staff)

    card_save(viewer, { email: "riley.new@example.net" })
    expect(response).to have_http_status(:forbidden)
    expect(employee.reload.email).to eq("riley.old@example.net")
    expect(invite.link.reload.invite_open?).to be(true)
    expect(AuditLog.where(record_type: "employees", record_id: employee.id, user_id: viewer.id)).to be_empty
  end

  it "lets a Client viewer read the contact fields the card shows" do
    get "/api/v1/client/employees/#{employee.id}", headers: bearer(viewer.clerk_id).merge("X-Company-Id" => company.id.to_s)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body["data"]).to include("email" => "riley.old@example.net", "phone" => "+16715550100")
    expect(response.parsed_body.dig("data", "contact_revision")).to be_present
  end
end
