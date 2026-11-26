# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin payroll overrides", type: :request do
  let(:company) { create(:company) }
  let(:role) { "admin" }
  let(:actor) { create(:user, company: company, role: role, clerk_id: "user_track_h1_fixture") }
  let(:period) { create(:pay_period, :committed, company: company, committed_by_id: actor.id) }
  let(:age) { 0 }
  let(:impersonated) { false }
  let(:reason) { "Fixture correction for duplicate payroll inputs" }
  let(:route) { "/api/v1/admin/pay_periods/#{period.id}" }

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
    rollback
    expect(response).to have_http_status(:ok), response.body
    staff, client = %w[staff client].map { |audience| PortalNotificationEvent.find_by!(event_type: "payroll_rollback_#{audience}", subject: period) }
    expect(client.deliveries.pluck(:user_id)).to eq([ manager.id ])
    expect(staff.deliveries.pluck(:user_id)).to contain_exactly(super_admin.id, accountant.id)
    [ staff, client ].each do |event|
      expect(event.metadata.keys).to contain_exactly("pay_period_id", "self_override")
      email = PortalNotifications::Email.new(audience: event.audience, delivery_mode: "immediate", events: [ event ])
      expect(email.subject).to include(company.name)
      expect(email.text).not_to include(reason)
      expect(email.html).not_to include(reason)
    end
    expect(staff.metadata["self_override"]).to be(true)
    expect(client.metadata["self_override"]).to be(false)
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

    rollback(acknowledge_later_runs: true)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("pay_period", "admin_rollback")).to be(true)
    expect(later_runs.map { |run| run.reload.rollback_review_required? }).to eq([ true, true ])
  end
end
