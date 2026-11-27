# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "PATCH /api/v1/admin/companies/:company_id/operating_profile", type: :request do
  let(:company) { create(:company, name: "Fictional Payroll Client") }
  let(:role) { "org_admin" }
  let(:access_level) { nil }
  let(:actor) { create(:user, company: company, organization: company.organization, role: role) }
  let(:path) { "/api/v1/admin/companies/#{company.id}/operating_profile" }
  let(:effective_on) { PayrollBusinessClock.today - 14 }
  let(:initial_date) { effective_on - 30 }
  let!(:pay_period) do
    create(:pay_period, company: company, start_date: effective_on, end_date: effective_on + 13, pay_date: effective_on + 18)
  end

  before do
    create(:company_assignment, user: actor, company: company, workspace_access_level: access_level)
    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(actor.id)
  end

  def update_profile(headers: {}, changes: { "tips.default" => "already_paid_out" }, **overrides)
    patch path, params: {
      effective_on: effective_on.iso8601, lock_version: 0, reason: "Document the client's operating terms", changes: changes
    }.merge(overrides), headers: headers, as: :json
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

  %w[client employee portal_employee].each do |role_name|
    context "as a #{role_name}" do
      let(:role) { role_name }

      it "denies the write" do
        expect { update_profile }.not_to change(ClientOperatingProfile, :count)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  it "rejects a company header that differs from the route" do
    other = create(:company, organization: company.organization)
    update_profile(headers: { "X-Company-Id" => other.id.to_s })
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects a foreign organization and returns 404 for a missing company" do
    foreign = create(:company)
    patch "/api/v1/admin/companies/#{foreign.id}/operating_profile", as: :json
    expect(response).to have_http_status(:forbidden)

    patch "/api/v1/admin/companies/#{Company.maximum(:id) + 1}/operating_profile", as: :json
    expect(response).to have_http_status(:not_found)
  end

  context "as an assigned accountant" do
    let(:role) { "accountant" }

    it "rejects another company in the same organization" do
      unassigned = create(:company, organization: company.organization)
      patch "/api/v1/admin/companies/#{unassigned.id}/operating_profile", as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "allows delegated administration and configuration but denies organization settings" do
      grantor = create(:user, company: company, role: "org_admin")
      actor.company_assignments.find_by!(company: company).update!(client_management: true, granted_by: grantor)

      update_profile(changes: { hours_source: "salaried_only" })
      expect(response).to have_http_status(:forbidden)

      update_profile(changes: { client_portal_enabled: true, "tips.default" => "already_paid_out" })
      expect(response).to have_http_status(:ok)
    end
  end

  context "in a test workspace" do
    let(:source_company) { create(:company) }
    let(:company) do
      create(:company, organization: source_company.organization, payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox", migration_source_company: source_company, migration_rehearsal_status: "ready")
    end

    let(:access_level) { "workspace_admin" }

    it "rejects a sealed workspace" do
      company.update_columns(test_workspace_sealed_at: Time.current)
      update_profile
      expect(response).to have_http_status(:forbidden)
    end

    it "returns conflict while preparation is pending" do
      company.update_columns(migration_rehearsal_status: "pending")
      update_profile
      expect(response).to have_http_status(:conflict)
    end

    context "with reviewer access" do
      let(:role) { "accountant" }
      let(:access_level) { "reviewer" }

      it "rejects PATCH even for a filing field" do
        update_profile(changes: { "year_end.kind_of_employer" => "S" })
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "with operator access" do
      let(:role) { "manager" }
      let(:access_level) { "operator" }

      it "can change a filing field within payroll operations" do
        update_profile(changes: { "year_end.kind_of_employer" => "S" })
        expect(response).to have_http_status(:ok)
      end

      it "rejects protected client administration and configuration settings" do
        [ { client_portal_enabled: true }, { "tips.default" => "already_paid_out" } ].each do |changes|
          update_profile(changes: changes)
          expect(response).to have_http_status(:forbidden)
        end
      end
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

  it "corrects the latest future draft in place and records exactly one audit per save" do
    start = PayrollBusinessClock.today + 14
    create(:pay_period, company: company, start_date: start, end_date: start + 13, pay_date: start + 18)
    audit_count = -> { AuditLog.where(action: ClientOperatingProfiles::UpdateService::AUDIT_ACTION, company_id: company.id).count }

    expect { update_profile(effective_on: start.iso8601) }.to change(&audit_count).by(1)
    expect(response).to have_http_status(:ok)
    saved = response.parsed_body.fetch("saved")
    expect(response.parsed_body.fetch("available_effective_dates")).to eq([ start.iso8601 ])
    baseline = company.client_operating_profiles.find_by!(version: 1)
    baseline_attributes = baseline.attributes

    expect {
      update_profile(effective_on: start.iso8601, lock_version: 1, changes: { "year_end.kind_of_employer" => "S" })
    }.to change(&audit_count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("saved")).to include("id" => saved.fetch("id"), "version" => 2, "lock_version" => 2)
    expect(company.client_operating_profiles.count).to eq(2)
    expect(baseline.reload.attributes).to eq(baseline_attributes)
    audits = AuditLog.where(action: ClientOperatingProfiles::UpdateService::AUDIT_ACTION, record_id: saved.fetch("id")).order(:id)
    expect(audits.first.metadata).to include("amended" => false)
    expect(audits.last.metadata).to include(
      "amended" => true, "before_values" => { "year_end.kind_of_employer" => "N" },
      "after_values" => { "year_end.kind_of_employer" => "S" }
    )
    expect(ClientOperatingProfiles::ParityChecker.call(companies: Company.where(id: company.id), on: start)).to be_passed
  end

  it "allows the first draft date when it is already the legacy baseline start" do
    baseline = ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: effective_on)
    )

    get path
    expect(response.parsed_body.fetch("available_effective_dates")).to include(effective_on.iso8601)
    update_profile
    expect(response).to have_http_status(:ok)
    expect(baseline.reload).to have_attributes(effective_on: effective_on - 1, ends_on: effective_on - 1, version: 1)
    expect(response.parsed_body.fetch("saved")).to include("version" => 2, "effective_on" => effective_on.iso8601)
    expect(response.parsed_body.fetch("available_effective_dates")).to be_empty
  end

  it "rejects an earlier date or an amendment when the latest version is already effective" do
    earlier = effective_on - 14
    create(:pay_period, company: company, start_date: earlier, end_date: earlier + 13, pay_date: earlier + 18)
    update_profile
    expect(response).to have_http_status(:ok)

    [ earlier, effective_on ].each do |date|
      expect {
        update_profile(effective_on: date.iso8601, lock_version: 1, changes: { "year_end.kind_of_employer" => "S" })
      }.not_to change { [ ClientOperatingProfile.count, AuditLog.count ] }
      expect(response).to have_http_status(422)
    end
  end

  it "rejects amending a future version once its run has been calculated" do
    start = PayrollBusinessClock.today + 14
    future_run = create(:pay_period, company: company, start_date: start, end_date: start + 13, pay_date: start + 18)
    update_profile(effective_on: start.iso8601)
    expect(response).to have_http_status(:ok)
    future_run.update_columns(status: "calculated")

    update_profile(effective_on: start.iso8601, lock_version: 1, changes: { "year_end.kind_of_employer" => "S" })
    expect(response).to have_http_status(422)
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

  it "refuses to activate every M4–M6 switch (including locked enum lifecycle mode) even for an org admin" do
    OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS.each do |key|
      entry = OperatingProfileCatalog.fetch(key)
      attempted_value = entry.type == "enum" ? (entry.allowed - [ entry.default ]).first : true
      changes = { key => attempted_value }
      changes["client_portal_enabled"] = true if entry.requires.include?("client_portal_enabled")

      update_profile(changes: changes)
      expect(response).to have_http_status(422)
      expect(response.parsed_body.fetch("error")).to include("locked")
    end
    expect(company.client_operating_profiles).to be_empty
  end

  it "rejects nested and truthy switch values and locks dependent settings" do
    [
      { options: { time_module_enabled: true } },
      { employee_portal: { features: { stubs: true } } },
      { employee_portal_enabled: "true" },
      { "employee_portal.features.pto" => 1 },
      { "employee_portal.former_access_years" => 7 }
    ].each do |changes|
      expect { update_profile(changes: changes) }.not_to change { [ ClientOperatingProfile.count, AuditLog.count ] }
      expect(response).to have_http_status(422)
    end
  end

  it "honors write maintenance before inserting a profile or audit" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return("true")

    expect { update_profile }.not_to change { [ ClientOperatingProfile.count, AuditLog.count ] }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.fetch("code")).to eq("write_maintenance")
  end
end
