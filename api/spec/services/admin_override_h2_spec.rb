# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminOverrideService do
  let(:company) { create(:company) }
  let(:admin) { create(:user, role: :admin, company: company) }
  let(:reason) { "Review the synthetic payroll records" }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:later_period) { create(:pay_period, :committed, company: company, rollback_review_required: true) }

  def retry_job(actor: admin, verified: true, impersonated: false, key: "stub_posting")
    described_class.retry_job!(company: company, actor: actor, verified: verified,
      impersonated: impersonated, job_key: key, reason: reason)
  end

  def review_evidence
    AdminOverride.create!(company: company, subject: period, actor: admin, action: "void_pay_period", reason: reason,
      before_snapshot: {}, after_snapshot: {}, preflight_result: { later_committed_run_ids: [ later_period.id ] })
  end

  User.roles.each_key do |role|
    it "enforces the retry capability for #{role}" do
      actor = create(:user, role: role, company: company)
      if %w[super_admin org_admin admin].include?(role)
        expect { retry_job(actor: actor) }.to change(AdminOverride, :count).by(1)
        expect(AdminOverride.last).to have_attributes(company_id: company.id, action: "retry_stub_posting", reason: reason)
      else
        expect { retry_job(actor: actor) }.to raise_error(described_class::AccessDenied)
      end
    end

    it "enforces the review completion capability for #{role}" do
      actor = create(:user, role: role, company: company)
      review_id = review_evidence.id
      complete = -> do
        described_class.complete_rollback_review!(period: later_period, actor: actor, impersonated: false, reason: reason, review_id: review_id)
      end
      if %w[super_admin org_admin admin manager accountant].include?(role)
        expect(&complete).to change { later_period.reload.rollback_review_required? }.from(true).to(false)
        expect(AdminOverride.last).to have_attributes(actor: actor, action: "complete_rollback_review")
      else
        expect(&complete).to raise_error(described_class::AccessDenied)
        expect(later_period.reload).to be_rollback_review_required
      end
    end
  end

  it "refuses impersonation, stale sign-in and jobs outside the allow-list" do
    expect { retry_job(verified: false) }.to raise_error(described_class::AccessDenied, /fresh/)
    expect { retry_job(impersonated: true) }.to raise_error(described_class::AccessDenied, /Sign in as/)
    expect { retry_job(key: "ApplicationJob") }.to raise_error(ArgumentError, /Choose/)
    expect { retry_job(key: "notification_dispatch") }.to change(AdminOverride, :count).by(1)
  end

  it "enqueues one company-scoped job and records the job ID" do
    expect { retry_job }.to have_enqueued_job(PostEmployeePayStubsJob).with(company.id)
    expect(AdminOverride.last.after_snapshot).to include("job" => "stub_posting", "job_id" => be_present)
  end

  it "does not queue work when its notification ledger fails" do
    allow(PortalNotifications).to receive(:admin_override!).and_raise(ActiveRecord::RecordInvalid)
    expect do
      expect { retry_job }.to raise_error(ActiveRecord::RecordInvalid)
    end.not_to have_enqueued_job(PostEmployeePayStubsJob)
    expect(AdminOverride.where(action: "retry_stub_posting")).to be_empty
  end

  it "refuses a stale review after a second rollback and refuses impersonation" do
    first = review_evidence.id
    review_evidence
    complete = lambda do |impersonated|
      described_class.complete_rollback_review!(period: later_period, actor: admin,
        impersonated: impersonated, reason: reason, review_id: first)
    end
    expect { complete.call(false) }.to raise_error(ArgumentError, /changed/)
    expect { complete.call(true) }.to raise_error(described_class::AccessDenied)
    expect(later_period.reload).to be_rollback_review_required
  end

  describe "atomic financial rollback" do
    let!(:employee) { create(:employee, company: company) }
    let!(:item) { create(:payroll_item, employee: employee, pay_period: period, net_pay: 0) }
    let!(:document) do
      EmployeeDocument.create!(company: company, payroll_item: item, status: "posted", revision: 1,
        storage_key: "employee_documents/test/trackh2.pdf", sha256: "a" * 64, posted_at: Time.current)
    end
    let!(:filing) { Form500Filing.create!(company: company, pay_period: period, status: "prepared", fields: { sample: true }) }

    def rollback
      described_class.rollback_payroll!(pay_period: period, actor: admin, verified: true,
        impersonated: false, reason: reason, confirmation: described_class.payroll_confirmation(period), unpaid_acknowledgement: true)
    end

    it "withdraws the stub and cancels the filing without queuing an employee email" do
      rollback
      expect(document.reload).to have_attributes(status: "withdrawn", withdrawal_reason: "rollback")
      expect(filing.reload.status).to eq("cancelled")
      expect(PortalNotificationEvent.distinct.pluck(:event_type)).to eq([ "payroll_reopened" ])
    end

    it "leaves the stub posted and filing prepared if notification evidence fails" do
      allow(PortalNotifications).to receive(:payroll_reopened!).and_raise(ActiveRecord::RecordInvalid)
      expect { rollback }.to raise_error(ActiveRecord::RecordInvalid)
      expect(document.reload).to be_posted
      expect(filing.reload.status).to eq("prepared")
      expect(period.reload).not_to be_voided
    end

    %w[paid filed].each do |status|
      it "blocks rollback for a #{status} filing" do
        filing.update!(status: status)
        expect { rollback }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /paid or submitted tax/)
        expect(document.reload).to be_posted
        expect(filing.reload.status).to eq(status)
      end
    end
  end
end
