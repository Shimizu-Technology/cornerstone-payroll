# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Portal notification catalog", :portal_notifications do
  include ActiveSupport::Testing::TimeHelpers
  include EmployeeLinkHelpers

  let(:company) { create(:company, name: "Synthetic Client") }
  let(:staff) { create(:user, role: "admin", company: company) }
  let(:manager) { create(:user, role: "client", company: company, client_access_level: "manager") }
  let(:viewer) { create(:user, role: "client", company: company, client_access_level: "viewer") }
  let(:employee) { create(:employee, company: company, first_name: "PrivateEmployee", email: "synthetic@example.test") }
  let(:foreign_staff) { create(:user, role: "super_admin") }
  let(:period) { create(:pay_period, company: company, status: "committed", committed_at: 1.minute.ago) }

  before do
    create(:company_assignment, user: manager, company: company)
    create(:company_assignment, user: viewer, company: company)
    list_portal_recipient!(company, user: staff)
    list_portal_recipient!(company, email: foreign_staff.email)
  end

  def assert_delivery(event, user, mode)
    expect(event.deliveries.find_by!(user: user)).to have_attributes(delivery_mode: mode, status: "pending")
  end

  def assert_opt_out(event, user, mode)
    assert_delivery(event, user, mode)
    PortalNotifications::Preferences.update!(user, event.category => "off")
    travel_to(event.deliveries.find_by!(user: user).deliver_after + 1.second) do
      PortalNotifications::Dispatcher.run!
    end
    expect(event.deliveries.find_by!(user: user).reload.skip_reason).to eq("preference_off")
    expect(captured_portal_emails.pluck(:to)).not_to include(user.email, foreign_staff.email)
  end

  def assert_copy(event, path)
    email = PortalNotifications::Email.new(audience: event.audience, delivery_mode: "digest", events: [ event ])
    payload = email.payload(from: "alerts@example.test", to: staff.email)
    expect(payload[:subject]).to include(company.name)
    expect(payload[:text]).to include("/companies/#{company.id}/#{path}")
    expect(payload[:html]).to include('role="presentation"')
    expect([ payload, event.metadata ].to_json).not_to include("PrivateEmployee", "PrivateReason", "1234.56")
  end

  it "records one final-payroll digest per eligible client audience and honors opt-out" do
    with_portal_email do
      2.times { PortalNotifications.payroll_committed!(period, actor: staff) }
      events = PortalNotificationEvent.where(event_type: "payroll_committed")
      expect(events.count).to eq(2)
      expect(events.flat_map { |event| event.deliveries.pluck(:user_id) }).to contain_exactly(manager.id, viewer.id)
      manager_event = events.detect(&:client_managers_only?)
      viewer_event = events.detect(&:client_viewers_only?)
      assert_copy(manager_event, "pay-runs/#{period.id}/overview")
      assert_delivery(viewer_event, viewer, "digest")
      assert_opt_out(manager_event, manager, "digest")
      expect(captured_portal_emails.pluck(:to)).to eq([ viewer.email ])
    end
  end

  it "exposes an H2 hook with a mandatory in-org super-admin audience" do
    supervisor = create(:user, role: "super_admin", company: company)
    actor = create(:user, role: "super_admin", company: company)
    period.update_columns(correction_status: "voided")
    with_portal_email do
      2.times { PortalNotifications.payroll_reopened!(period, actor: actor, action_id: 15) }
      events = PortalNotificationEvent.where(event_type: "payroll_reopened")
      expect(events.count).to eq(4)
      oversight = events.detect(&:super_admin_alert?)
      expect(oversight.deliveries.pluck(:user_id)).to eq([ supervisor.id ])
      assert_delivery(oversight, supervisor, "immediate")
      assert_delivery(events.detect(&:client_managers_only?), manager, "immediate")
      assert_delivery(events.detect(&:client_viewers_only?), viewer, "digest")
      assert_copy(oversight, "pay-runs/#{period.id}/work")
      expect { PortalNotifications::Preferences.update!(supervisor, oversight.category => "off") }.to raise_error(ArgumentError)
    end
  end

  it "sends contact confirmations by digest to managers other than the actor and to the account team" do
    enable_employee_app!(company)
    company.client_operating_profiles.last.update!(options: { employee_portal: { features: { profile_requests: true } } })
    actor = create(:user, :with_client_assignment, company: company)
    entry = EmployeeContactChangeToConfirm.create!(company: company, employee: employee, changed_by: actor, change_kind: "contact",
      before_values: {}, after_values: { phone: "1234.56" })
    with_portal_email do
      PortalNotifications.employee_contact_changed!(entry, actor: actor)
      client_event = PortalNotificationEvent.find_by!(event_type: "employee_contact_changed")
      staff_event = PortalNotificationEvent.find_by!(event_type: "employee_contact_confirmation_requested")
      expect(client_event.deliveries.pluck(:user_id)).to eq([ manager.id ])
      assert_copy(client_event, "change-requests?view=contact")
      assert_copy(staff_event, "contact-changes-to-confirm")
      assert_delivery(staff_event, staff, "digest")
      assert_opt_out(client_event, manager, "digest")
    end
  end

  %w[employee_signup_locked employee_invite_expiring].each do |event_type|
    it "sends #{event_type} only to the account team by digest and honors opt-out" do
      enable_employee_app!(company)
      link = invite!(employee, actor: staff, delivery: "code").link
      now = Time.current
      if event_type == "employee_signup_locked"
        link.update!(activation_locked_at: now, activation_locked_until: now + 24.hours)
        generation = link.activation_locked_at
      else
        link.update!(invite_expires_at: now + 2.days)
      end
      with_portal_email do
        2.times do
        if event_type == "employee_invite_expiring"
          ExpireEmployeeLinksJob.perform_now(now: now)
        else
          PortalNotifications.employee_link_event!(event_type, link, generation: generation)
        end
      end
        event = PortalNotificationEvent.find_by!(event_type: event_type)
        expect(event.deliveries.where.not(user_id: nil).pluck(:user_id)).to eq([ staff.id ])
        assert_copy(event, "employee-app/rollout")
        assert_opt_out(event, staff, "digest")
      end
    end
  end

  it "alerts only the account team when current W-2s are ready to post" do
    filing = W2FilingReadiness.create!(company: company, year: 2025, status: "filing_ready",
      notes: "PrivateReason", attestation_history: [ { "notes" => "PrivateReason" } ])
    allow(EmployeeDocuments::PostW2GuCopies).to receive(:new).and_return(instance_double(EmployeeDocuments::PostW2GuCopies, posting_pending?: true))
    with_portal_email do
      2.times { PortalNotifications.w2_ready_to_post!(filing, actor: nil) }
      event = PortalNotificationEvent.find_by!(event_type: "w2_ready_to_post")
      expect(event.deliveries.where.not(user_id: nil).pluck(:user_id)).to eq([ staff.id ])
      assert_copy(event, "year-end?year=2025")
      assert_opt_out(event, staff, "immediate")
    end
  end
end
