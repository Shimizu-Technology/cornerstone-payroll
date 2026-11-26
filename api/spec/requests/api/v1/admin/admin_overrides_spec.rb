# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin payroll overrides", type: :request, portal_notifications: true do
  let(:company) { create(:company) }
  let(:role) { "admin" }
  let(:actor) { create(:user, company: company, role: role, clerk_id: "user_track_h1_fixture") }
  let(:period) { create(:pay_period, :committed, company: company, committed_by_id: actor.id) }
  let(:age) { 0 }
  let(:impersonated) { false }
  let(:reason) { "Fixture correction for duplicate payroll inputs" }
  let(:route) { "/api/v1/admin/pay_periods/#{period.id}" }

  include ActiveSupport::Testing::TimeHelpers
  include EmployeeLinkHelpers

  def payroll_headers
    claims = { fva: [ age, age ], two_factor_enabled: true }
    claims[:act] = { sub: "user_fixture_impersonator" } if impersonated
    bearer(actor.clerk_id, **claims).merge("X-Company-Id" => company.id.to_s)
  end

  def rollback(action = "void", **overrides)
    post "#{route}/#{action}", params: {
      reason: reason, confirmation: AdminOverrideService.payroll_confirmation(period),
      unpaid_acknowledgement: true
    }.merge(overrides), headers: payroll_headers, as: :json
  end

  User.roles.each_key do |candidate|
    context "as #{candidate}" do
      let(:role) { candidate }

      it "enforces break-glass access" do
        rollback
        if %w[super_admin org_admin admin].include?(candidate)
          expect(response).to have_http_status(:ok), response.body
          expect(AdminOverride.last).to have_attributes(actor: actor, subject: period, self_override: true)
        else
          expect(response).to have_http_status(:forbidden)
          expect(period.reload).not_to be_voided
        end
      end
    end
  end

  context "with a stale session" do
    let(:age) { 20 }

    it "refuses both actions and prompts for reverification" do
      %w[void reopen_unpaid].each do |action|
        rollback(action)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body.dig("clerk_error", "reason")).to eq("reverification-error")
      end
      expect(period.reload).not_to be_voided
    end
  end

  context "inside Sign in as" do
    let(:impersonated) { true }

    it "refuses both actions" do
      %w[void reopen_unpaid].each do |action|
        rollback(action)
        expect(response).to have_http_status(:forbidden)
      end
      expect(period.reload).not_to be_voided
    end
  end

  it "rejects missing, short, oversized and mismatched confirmation inputs" do
    [ { reason: nil }, { reason: "short" }, { reason: "x" * 1001 }, { confirmation: "wrong" } ].each do |overrides|
      rollback(**overrides)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(period.reload).not_to be_voided
    end
    expect(AdminOverride.count).to eq(0)
  end

  it "rolls back the financial action, override and notification when the audit fails" do
    allow(AuditLog).to receive(:record!).and_call_original
    allow(AuditLog).to receive(:record!).with(hash_including(action: "void_pay_period"))
      .and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
    expect { rollback }.not_to change(PayPeriodCorrectionEvent, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.reload).not_to be_voided
    expect(AdminOverride.count).to eq(0)
    expect(PortalNotificationEvent.where(subject: period)).to be_empty
  end

  it "rolls back the financial action and audit writes when the notification ledger fails" do
    allow(PortalNotificationDelivery).to receive(:create!).and_call_original
    allow(PortalNotificationDelivery).to receive(:create!).with(satisfy { |attributes|
      attributes.fetch(:portal_notification_event).super_admin_alert?
    }).and_raise(ActiveRecord::RecordInvalid.new(PortalNotificationDelivery.new))

    expect { rollback }.not_to change(PayPeriodCorrectionEvent, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.reload).not_to be_voided
    expect(AdminOverride.where(subject: period)).to be_empty
    expect(AuditLog.where(action: "void_pay_period", record_type: "PayPeriod", record_id: period.id)).to be_empty
    expect(PortalNotificationEvent.where(subject: period)).to be_empty
  end

  it "protects recorded overrides from SQL updates, deletes and truncation" do
    rollback
    expect(response).to have_http_status(:ok), response.body
    %w[UPDATE DELETE TRUNCATE].zip([
      "UPDATE admin_overrides SET reason = 'tampered fixture reason'",
      "DELETE FROM admin_overrides",
      "TRUNCATE admin_overrides"
    ]).each do |verb, sql|
      expect {
        AdminOverride.transaction(requires_new: true) { AdminOverride.connection.execute(sql) }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/), verb
    end
  end

  it "keeps the reason and payroll details out of rollback alerts and flags self-override" do
    super_admin = create(:user, company: company, role: "super_admin")
    accountant = create(:user, company: company, role: "accountant")
    create(:company_assignment, user: accountant, company: company)
    PortalNotificationRecipient.create!(company: company, user: accountant)
    manager = create(:user, company: company, role: "client", client_access_level: "manager")
    viewer = create(:user, company: company, role: "client", client_access_level: "viewer")
    [ manager, viewer ].each { |user| create(:company_assignment, user: user, company: company) }
    PortalNotificationRecipient.create!(company: company, user: super_admin)
    PortalNotificationPreference.create!(user: super_admin, category: "payroll_submissions", delivery_mode: "off")

    with_portal_email do
      rollback
      expect(response).to have_http_status(:ok), response.body
      events = PortalNotificationEvent.where(event_type: "payroll_reopened", subject: period)
      staff, client, viewer_update, alert = %w[account_team client_managers client_viewers super_admins].map do |scope|
        events.find_by!("metadata->>'recipient_scope' = ?", scope)
      end
      expect(events.count).to eq(4)
      expect(events.map { |event| event.metadata.fetch("revision") }.uniq).to eq([ AdminOverride.find_by!(subject: period).id ])
      expect(client.deliveries.pluck(:user_id)).to eq([ manager.id ])
      expect(viewer_update.deliveries.sole).to have_attributes(user_id: viewer.id, delivery_mode: "digest")
      expect(alert.category).to eq("payroll_super_admin")
      expect(staff.deliveries.pluck(:user_id)).to eq([ accountant.id ])
      expect(alert.deliveries.sole).to have_attributes(user_id: super_admin.id, delivery_mode: "immediate", status: "pending")
      expect(PortalNotifications::Preferences.categories_for(super_admin)).not_to have_key("payroll_super_admin")
      expect { PortalNotifications::Preferences.update!(super_admin, "payroll_super_admin" => "off") }
        .to raise_error(ArgumentError, /Unknown notification category/)

      events.each do |event|
        expect(event.metadata.keys - %w[period_id revision self_override recipient_scope]).to be_empty
        email = PortalNotifications::Email.new(audience: event.audience, delivery_mode: "immediate", events: [ event ])
        expect(email.subject).to include(company.name)
        expect(email.text).not_to include(reason)
        expect(email.html).not_to include(reason)
      end
      expect(alert.metadata["self_override"]).to be(true)
      expect([ staff, client, viewer_update ]).to all(satisfy { |event| !event.metadata.key?("self_override") })

      travel(3.minutes) { PortalNotifications::Dispatcher.run! }
      expect(alert.deliveries.sole.status).to eq("sent")
      oversight_emails = captured_portal_emails.select { |email| email[:to] == super_admin.email }
      expect(oversight_emails.sole.fetch(:subject)).to include("Payroll rolled back by its own operator")
    end
  end

  it "rejects untrusted callers of both correction engine entry points" do
    %i[void! reopen_unpaid!].each do |action|
      expect {
        PayPeriodCorrectionService.public_send(action, authorization: Object.new, pay_period: period, actor: actor, reason: reason)
      }.to raise_error(AdminOverrideService::AccessDenied)
    end
    expect(period.reload).not_to be_voided
  end

  it "rechecks archive and practice-copy safety through the service entry point" do
    target = period
    options = { pay_period: target, actor: actor, reason: reason, verified: true, impersonated: false,
      confirmation: AdminOverrideService.payroll_confirmation(target), unpaid_acknowledgement: true }
    company.update_columns(test_workspace_archived_at: Time.current)
    expect { AdminOverrideService.rollback_payroll!(**options) }.to raise_error(AdminOverrideService::AccessDenied)

    company.update_columns(test_workspace_archived_at: nil)
    allow_any_instance_of(Company).to receive(:practice_copy?).and_return(true)
    expect { AdminOverrideService.rollback_payroll!(**options) }.to raise_error(AdminOverrideService::AccessDenied)
    expect(target.reload).not_to be_voided
  end

  it "flags same-date later runs with tied or absent commit timestamps" do
    employee = create(:employee, company: company)
    create(:payroll_item, pay_period: period, employee: employee)
    later_runs = [ period.committed_at, nil ].map do |committed_at|
      create(:pay_period, :committed, company: company, pay_date: period.pay_date).tap do |run|
        run.update_columns(committed_at: committed_at)
        create(:payroll_item, pay_period: run, employee: employee)
      end
    end
    rollback("reopen_unpaid")
    expect(response.parsed_body.fetch("error")).to include("later payroll")
    rollback(acknowledge_later_runs: true)
    expect(response).to have_http_status(:ok), response.body
    expect(later_runs).to all(satisfy { |run| run.reload.rollback_review_required? })
  end

  it "blocks reopening and requires acknowledgement before flagging later committed runs" do
    employee = create(:employee, company: company)
    create(:payroll_item, pay_period: period, employee: employee)
    later_runs = [ 14, 28 ].map do |days|
      create(:pay_period, :committed, company: company, start_date: period.start_date + days,
        end_date: period.end_date + days, pay_date: period.pay_date + days).tap do |run|
        create(:payroll_item, pay_period: run, employee: employee)
      end
    end

    rollback("reopen_unpaid", acknowledge_later_runs: true)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("later payroll")
    rollback
    expect(response).to have_http_status(:unprocessable_entity)
    expect(later_runs.map { |run| run.reload.rollback_review_required? }).to eq([ false, false ])

    rollback(acknowledge_later_runs: "true")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("pay_period", "admin_rollback")).to be(true)
    expect(later_runs.map { |run| run.reload.rollback_review_required? }).to eq([ true, true ])
  end
end
