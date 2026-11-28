# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee lifecycle notification catalog", :portal_notifications do
  include ActiveSupport::Testing::TimeHelpers
  include EmployeeLifecyclePr4Helpers

  let(:company) { create(:company, name: "Fictional Payroll Client", demo: demo) }
  let(:demo) { false }
  let(:employee) do
    create_lifecycle_worker!(company, email: "quinn.private@example.test", pay_rate: 47.23)
  end
  let(:staff) { create(:user, company: company, role: "manager", name: "Morgan Staff", email: "morgan@example.test") }
  let(:client) do
    create(:user, :with_client_assignment, company: company, role: "client", client_access_level: "manager",
      name: "Sloane Owner", email: "sloane@example.test")
  end

  before { unlock_lifecycle_mode! }
  after { travel_back }

  def queue!(worker = employee, actor: client, kind: "new_hire")
    EmployeeVerificationItems::Recorder.record!(employee: worker, actor: actor, event_kind: kind,
      changed_fields: %w[ssn_encrypted pay_rate email],
      after_values: { ssn_encrypted: "900-11-2233", pay_rate: 47.23, email: "quinn.private@example.test" })
  end

  def return!(item)
    EmployeeVerificationItems::Review.new(company_id: item.company_id, item_id: item.id, actor: staff)
      .call!(:return_to_client, return_note: "Ask Quinn Example to check the private fixture details.") { }
  end

  def dispatch_after_batch!
    travel_to(Time.current + PortalNotifications::BATCH_WINDOW + 1.second)
    PortalNotifications::Dispatcher.run!
  end

  def expect_safe_copy(mail, path:, subject:)
    expect(mail[:subject]).to eq(subject)
    expect(mail[:text]).to include(path)
    expect(mail[:html]).to include(path)
    expect([ mail[:subject], mail[:text], mail[:html] ].join(" ")).not_to include(
      "Quinn", "Sloane", "900-11-2233", "47.23", "quinn.private@example.test", "private fixture details"
    )
  end

  it "alerts only listed staff with client management and extras, and batches bursts into one email each" do
    create_client_managed_profile!(company)
    plain = create(:user, company: company, role: "accountant", name: "Taylor Accountant", email: "taylor@example.test")
    delegated = create(:user, company: company, role: "accountant", name: "Drew Delegate", email: "drew@example.test")
    grantor = create(:user, company: company, role: "org_admin", name: "Riley Admin", email: "riley@example.test")
    create(:company_assignment, company: company, user: delegated, client_management: true, granted_by: grantor)
    [ staff, plain, delegated ].each { |user| list_portal_recipient!(company, user: user) }
    list_portal_recipient!(company, email: "extra@alerts.example.test")

    with_portal_email do
      first = queue!
      first_due_at = PortalNotificationEvent.find_by!(subject: first).deliveries.first.deliver_after
      travel_to((Time.current + 1.minute).change(usec: 0))
      second = queue!(employee, kind: "compensation_change")
      PortalNotifications.employee_verification_queued!(second)
      events = PortalNotificationEvent.where(event_type: "employee_verification_queued")
      expect(events.count).to eq(2)
      event = events.find_by!(subject: first)
      expect(event.dedupe_key).to eq("employee_verification_queued:#{first.id}:#{first.updated_at.utc.iso8601(6)}")
      expect(event.deliveries.pluck(:user_id, :recipient_email)).to contain_exactly(
        [ staff.id, nil ], [ delegated.id, nil ], [ nil, "extra@alerts.example.test" ]
      )

      expect(events.flat_map { |entry| entry.deliveries.pluck(:deliver_after) }.uniq).to eq([ first_due_at ])
      travel_to(first_due_at + 1.second)
      PortalNotifications::Dispatcher.run!
      expect(captured_portal_emails.pluck(:to)).to contain_exactly(staff.email, delegated.email, "extra@alerts.example.test")
      captured_portal_emails.each do |mail|
        expect_safe_copy(mail, path: "/companies/#{company.id}/verifications",
          subject: "Employee updates to verify — #{company.name}")
      end
    end
  end

  it "rechecks delegated staff access and suppresses queued alerts once verified" do
    create_client_managed_profile!(company)
    delegated = create(:user, company: company, role: "accountant", name: "Drew Delegate", email: "drew@example.test")
    grantor = create(:user, company: company, role: "org_admin", name: "Riley Admin", email: "riley@example.test")
    assignment = create(:company_assignment, company: company, user: delegated, client_management: true, granted_by: grantor)
    [ staff, delegated ].each { |user| list_portal_recipient!(company, user: user) }

    with_portal_email do
      unresolved = queue!
      resolved = queue!(employee, kind: "compensation_change")
      EmployeeVerificationItems::Review.new(company_id: company.id, item_id: resolved.id, actor: staff).call!(:verify, {}) { }
      assignment.update!(client_management: false)
      dispatch_after_batch!

      expect(captured_portal_emails.pluck(:to)).to eq([ staff.email ])
      expect(PortalNotificationEvent.find_by!(subject: resolved).deliveries.pluck(:skip_reason).uniq).to eq([ "resource_unavailable" ])
      expect(PortalNotificationEvent.find_by!(subject: unresolved).deliveries.find_by!(user: delegated).skip_reason).to eq("access_revoked")
    end
  end

  it "sends returns to assigned active client managers only and makes prior alerts stale on resubmission" do
    create_client_managed_profile!(company)
    viewer = create(:user, :with_client_assignment, company: company, role: "client", client_access_level: "viewer",
      name: "Sky Viewer", email: "sky@example.test")
    create(:user, company: company, role: "client", client_access_level: "manager", name: "Parker Unassigned", email: "parker@example.test")
    list_portal_recipient!(company, user: staff)

    with_portal_email do
      item = queue!
      return!(item)
      event = PortalNotificationEvent.find_by!(event_type: "employee_verification_returned", subject: item)
      PortalNotifications.employee_verification_returned!(item.reload)
      expect(event).to be_client_managers_only
      expect(event.deliveries.pluck(:user_id)).to eq([ client.id ])
      expect(event.deliveries.pluck(:user_id)).not_to include(viewer.id)
      expect(event.dedupe_key).to eq("employee_verification_returned:#{item.id}:#{item.returned_at.utc.iso8601(6)}")

      dispatch_after_batch!
      expect(captured_portal_emails.pluck(:to)).to eq([ client.email ])
      expect_safe_copy(captured_portal_emails.sole, path: "/companies/#{company.id}/employees?filter=needs_attention",
        subject: "Action needed on employee details — #{company.name}")

      other = queue!(employee, kind: "compensation_change")
      return!(other)
      travel_to(Time.current + 1.second)
      expect(queue!(employee, kind: "compensation_change").id).to eq(other.id)
      dispatch_after_batch!
      returned = PortalNotificationEvent.find_by!(event_type: "employee_verification_returned", subject: other)
      expect(returned.deliveries.sole.skip_reason).to eq("resource_unavailable")
      queued = PortalNotificationEvent.where(event_type: "employee_verification_queued", subject: other).order(:id)
      expect(queued.count).to eq(2)
      expect(queued.first.deliveries.sole.skip_reason).to eq("resource_unavailable")
      expect(queued.last.deliveries.sole.status).to eq("sent")
      expect(captured_portal_emails.pluck(:to)).to eq([ client.email, staff.email ])
    end
  end

  it "delivers a blocked activation even with zero listed staff and suppresses a later resolved notice" do
    profile = create_client_managed_profile!(company, lifecycle_mode_activated_at: nil)
    org_admin = create(:user, company: company, role: "org_admin", name: "Riley Admin", email: "riley@example.test")
    super_admin = create(:user, company: company, role: "super_admin", name: "Avery Platform", email: "avery@example.test")
    create(:user, company: company, role: "admin", name: "Drew Admin", email: "drew@example.test")
    create(:user, role: "super_admin", name: "Cameron Platform", email: "cameron@example.test")
    PortalNotifications::Preferences.update!(org_admin, "employee_verifications" => "off")

    with_portal_email do
      first_attempt = ClientOperatingProfiles::LifecycleModeActivationService.activate!(company: company, actor: org_admin)
      expect(first_attempt).to be_blocked
      expect(CompanyFeatures.for(company).employee_lifecycle_mode).to eq("approval_first")
      event = PortalNotificationEvent.find_by!(event_type: "lifecycle_mode_activation_blocked", subject: profile)
      expect(event.deliveries.pluck(:user_id)).to contain_exactly(org_admin.id, super_admin.id)
      expect(event.deliveries.pluck(:delivery_mode).uniq).to eq([ "immediate" ])
      expect(event.dedupe_key).to eq("lifecycle_mode_activation_blocked:#{profile.id}:#{profile.reload.lifecycle_mode_activation_failed_at.utc.iso8601(6)}")
      dispatch_after_batch!
      expect(captured_portal_emails.pluck(:to)).to contain_exactly(org_admin.email, super_admin.email)
      captured_portal_emails.each do |mail|
        expect_safe_copy(mail, path: "/companies/#{company.id}/settings/operating-profile",
          subject: "Scheduled Client-managed mode activation blocked — #{company.name}")
      end

      expect(ClientOperatingProfiles::LifecycleModeActivationService.activate!(company: company, actor: org_admin)).to be_blocked
      second = PortalNotificationEvent.where(event_type: "lifecycle_mode_activation_blocked", subject: profile).order(:id).last
      list_portal_recipient!(company, user: staff)
      expect(ClientOperatingProfiles::LifecycleModeActivationService.activate!(company: company, actor: org_admin)).to be_activated

      dispatch_after_batch!
      expect(second.deliveries.pluck(:skip_reason).uniq).to eq([ "resource_unavailable" ])
      expect(captured_portal_emails.size).to eq(2)
    end
  end

  context "with a demo company" do
    let(:demo) { true }

    it "contains alerts in the DemoOutbound allowlist, adds the prefix, and skips practice copies" do
      create_client_managed_profile!(company)
      saved = ENV[DemoOutbound::ENV_KEY]
      ENV[DemoOutbound::ENV_KEY] = "sloane@example.test,morgan@example.test,revoked@demo.example.test"
      list_portal_recipient!(company, user: staff)
      list_portal_recipient!(company, email: "revoked@demo.example.test")
      list_portal_recipient!(company, email: "blocked@demo.example.test")

      with_portal_email do
        item = queue!
        event = PortalNotificationEvent.find_by!(event_type: "employee_verification_queued", subject: item)
        expect(event.deliveries.find_by!(recipient_email: "blocked@demo.example.test").skip_reason).to eq("recipient_not_allowed")
        ENV[DemoOutbound::ENV_KEY] = "sloane@example.test,morgan@example.test"
        dispatch_after_batch!
        expect(event.deliveries.find_by!(recipient_email: "revoked@demo.example.test").skip_reason).to eq("recipient_not_allowed")
        expect(captured_portal_emails.pluck(:to).flatten).to eq([ staff.email ])
        expect_safe_copy(captured_portal_emails.sole, path: "/companies/#{company.id}/verifications",
          subject: "[Demo] Employee updates to verify — #{company.name}")

        production_source = create(:company, name: "Practice Source Fixture", organization: company.organization)
        practice = create(:company, organization: company.organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
          migration_source_company: production_source, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
        create_client_managed_profile!(practice)
        expect { queue!(create_lifecycle_worker!(practice), actor: nil) }.not_to change(PortalNotificationEvent, :count)
      end
    ensure
      ENV[DemoOutbound::ENV_KEY] = saved
    end
  end
end
