# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "PATCH /api/v1/admin/companies/:company_id/operating_profile", type: :request do
  let(:company) { create(:company, name: "Fictional Payroll Client") }
  let(:role) { "org_admin" }
  let(:actor) { create(:user, company: company, organization: company.organization, role: role) }
  let(:path) { "/api/v1/admin/companies/#{company.id}/operating_profile" }
  let(:effective_on) { PayrollBusinessClock.today - 14 }
  let(:initial_date) { effective_on - 30 }
  let!(:pay_period) do
    create(:pay_period, company: company, start_date: effective_on, end_date: effective_on + 13, pay_date: effective_on + 18)
  end

  before do
    create(:company_assignment, user: actor, company: company)
    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(actor.id)
  end

  def update_profile(changes: { "tips.default" => "already_paid_out" }, **overrides)
    patch path, params: {
      effective_on: effective_on.iso8601, lock_version: 0, reason: "Document the client's operating terms", changes: changes
    }.merge(overrides), as: :json
  end

  def create_baseline
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: initial_date)
    )
  end

  it "allows an organization admin to edit settings across all four capability groups and audits the exact diff" do
    previous = create_baseline
    changes = {
      "offering" => "workforce_suite",
      "client_portal_enabled" => true,
      "hours_source" => "connected_app",
      "tips.default" => "already_paid_out",
      "year_end.contact.name" => "Fictional Filing Contact"
    }

    expect { update_profile(changes: changes) }.to change { company.client_operating_profiles.count }.by(1)
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body).to include("lock_version" => 1, "connected_source_active" => false)
    expect(body.fetch("saved")).to include("version" => 2, "changed_by_id" => actor.id, "effective_on" => effective_on.iso8601)
    expect(previous.reload).to have_attributes(
      ends_on: effective_on - 1, offering: "payroll_service", hours_source: "manual", client_portal_enabled: false
    )
    expect(CompanyFeatures.for(company, on: effective_on - 1).version).to eq(1)
    expect(CompanyFeatures.for(company, on: effective_on).version).to eq(2)

    audit = AuditLog.find_by!(action: ClientOperatingProfiles::UpdateService::AUDIT_ACTION, company_id: company.id)
    expect(audit).to have_attributes(user: actor, actor_type: "staff_user", record_id: body.dig("saved", "id"))
    expect(audit.metadata).to include(
      "changed_fields" => match_array(changes.keys),
      "before_values" => {
        "offering" => "payroll_service", "client_portal_enabled" => false, "hours_source" => "manual",
        "tips.default" => "paid_in_check", "year_end.contact.name" => company.filing_contact_name
      },
      "after_values" => changes
    )
  end

  context "as a manager" do
    let(:role) { "manager" }

    it "denies changing hours source" do
      expect { update_profile(changes: { hours_source: "salaried_only" }) }.not_to change(ClientOperatingProfile, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "allows client administration and intake changes" do
      update_profile(changes: { "client_portal_enabled" => true, "tips.default" => "already_paid_out" })
      expect(response).to have_http_status(:ok)
    end
  end

  context "as an accountant" do
    let(:role) { "accountant" }

    it "denies changing the client portal" do
      expect { update_profile(changes: { client_portal_enabled: true }) }.not_to change(ClientOperatingProfile, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "allows changing a filing field" do
      update_profile(changes: { "year_end.kind_of_employer" => "S" })
      expect(response).to have_http_status(:ok)
    end
  end

  %w[calculated approved committed].each do |status|
    it "rejects a date at the start of a #{status} run" do
      pay_period.update_columns(status: status)
      expect { update_profile }.not_to change(ClientOperatingProfile, :count)
      expect(response).to have_http_status(422)
      expect(response.parsed_body.fetch("error")).to include("calculated, approved, or committed")
    end
  end

  it "rejects a date inside or outside a draft period" do
    [ effective_on + 1, effective_on + 14 ].each do |date|
      update_profile(effective_on: date.iso8601)
      expect(response).to have_http_status(422)
      expect(response.parsed_body.fetch("error")).to include("start of a draft pay period")
    end
  end

  it "rejects backdating to a draft if a later period is already committed" do
    create(:pay_period, :committed, company: company, start_date: effective_on + 14,
      end_date: effective_on + 27, pay_date: effective_on + 32)

    expect { update_profile }.not_to change(ClientOperatingProfile, :count)
    expect(response).to have_http_status(422)
  end

  it "validates requires against the resulting profile, including changes submitted together" do
    update_profile(changes: { "client_portal.sensitive_documents_visible" => true })
    expect(response).to have_http_status(422)
    expect(response.parsed_body.fetch("error")).to include("requires Client portal enabled")
    expect(company.client_operating_profiles).to be_empty

    update_profile(changes: { "client_portal_enabled" => true, "client_portal.sensitive_documents_visible" => true })
    expect(response).to have_http_status(:ok)
  end

  it "rejects switching off a prerequisite while its dependent setting is enabled" do
    previous = create_baseline
    previous.update!(client_portal_enabled: true, options: previous.options.deep_merge(
      "client_portal" => { "sensitive_documents_visible" => true }
    ))

    update_profile(lock_version: previous.lock_version, changes: { "client_portal_enabled" => false })
    expect(response).to have_http_status(422)
    expect(response.parsed_body.fetch("error")).to include("requires Client portal enabled")

    update_profile(lock_version: previous.lock_version, changes: {
      "client_portal_enabled" => false, "client_portal.sensitive_documents_visible" => false
    })
    expect(response).to have_http_status(:ok)
  end

  it "rolls back the preceding interval closure when the new version is invalid" do
    previous = create_baseline

    update_profile(changes: { "tips.default" => "already_paid_out", "year_end.contact.name" => [ "invalid" ] })
    expect(response).to have_http_status(422)
    expect(previous.reload).to have_attributes(ends_on: nil, lock_version: 0)
    expect(company.client_operating_profiles.count).to eq(1)
  end

  it "returns 409 for a stale lock_version before checking the effective date" do
    expect { update_profile }.to change { company.client_operating_profiles.count }.from(0).to(2)
    expect(response).to have_http_status(:ok)

    expect { update_profile(changes: { "year_end.kind_of_employer" => "S" }) }.not_to change(AuditLog, :count)
    expect(response).to have_http_status(:conflict)
    expect(company.client_operating_profiles.count).to eq(2)
  end

  it "uses the latest scheduled version and a fresh lock token for a second append" do
    create_baseline
    scheduled_start = PayrollBusinessClock.today + 14
    [ scheduled_start, scheduled_start + 14 ].each do |start|
      create(:pay_period, company: company, start_date: start, end_date: start + 13, pay_date: start + 18)
    end

    update_profile(effective_on: scheduled_start.iso8601)
    expect(response.parsed_body.dig("effective", "version")).to eq(1)
    expect(response.parsed_body.dig("saved", "version")).to eq(2)

    update_profile(effective_on: (scheduled_start + 14).iso8601, lock_version: 1, changes: { "year_end.kind_of_employer" => "S" })
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("lock_version" => 2)
    expect(company.client_operating_profiles.history_order.first.option_value("tips.default")).to eq("already_paid_out")
  end

  it "lazily creates a new client's legacy baseline and keeps parity passing with an audited edit" do
    expect(company.client_operating_profiles).to be_empty
    update_profile

    expect(response).to have_http_status(:ok)
    baseline, edited = company.client_operating_profiles.order(:version)
    expect(baseline).to have_attributes(version: 1, ends_on: effective_on - 1)
    expect(edited).to have_attributes(version: 2, effective_on: effective_on)
    expect(edited.option_value("tips.default")).to eq("already_paid_out")

    Rails.application.load_tasks unless Rake::Task.task_defined?("operating_profiles:parity")
    task = Rake::Task["operating_profiles:parity"]
    task.reenable
    expect { task.invoke }.to output(a_string_including("OK    operating_profiles:parity", "differences=0")).to_stdout

    edited.update!(options: edited.options.deep_merge("year_end" => { "contact" => { "name" => "Unaudited edit" } }))
    expect(ClientOperatingProfiles::ParityChecker.call.differences.map(&:field)).to eq([ "year_end.contact.name" ])
  end

  it "refuses to activate every M4–M6 switch even for an org admin" do
    OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS.each do |key|
      update_profile(changes: { key => true })
      expect(response).to have_http_status(422)
      expect(response.parsed_body.fetch("error")).to include("locked")
    end
    expect(company.client_operating_profiles).to be_empty
  end

  it "honors write maintenance before inserting a profile or audit" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return("true")

    expect { update_profile }.not_to change { [ ClientOperatingProfile.count, AuditLog.count ] }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.fetch("code")).to eq("write_maintenance")
  end
end
