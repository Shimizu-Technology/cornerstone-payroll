# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Main311 source and payment preservation" do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, :with_check, company: company, pay_period: period, employee: employee, hours_worked: 4, overtime_hours: 0) }

  %w[pending_commit committed issued voided].each do |status|
    it "holds generic reopening for retained #{status} manual Source lineage without source or financial commands" do
      source = create(:time_tracking_source, company: company, source_type: "aire_services")
      allocation = TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source, pay_period: period,
        payroll_item: item, employee: employee, created_by: actor, source_user_uuid: SecureRandom.uuid,
        source_time_entry_id: "preserved-41", source_time_entry_version: 2, original_work_date: period.start_date,
        regular_hours: 4, overtime_hours: 0, reconciliation_note: "Retained source ownership requires reviewed correction", status: status)
      original = [ period.reload.attributes, item.reload.attributes, allocation.reload.attributes ]
      expect(PayrollRevisionPaymentPreflight.new(pay_period: period).call(reopen: true)[:blockers])
        .to include("This payroll has linked time-source processing evidence; use a reviewed source correction")
      expect {
        PayPeriodCorrectionService.reopen_unpaid!(pay_period: period, actor: actor, reason: "Review retained source ownership first")
      }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /linked time-source/)
      expect([ period.reload.attributes, item.reload.attributes, allocation.reload.attributes ]).to eq(original)
      expect(item.check_events).to be_empty
      expect(AirePayrollEntryAcknowledgement.count).to eq(0)
      expect(PayPeriodCorrectionEvent.count).to eq(0)
    end
  end

  it "requires a successful locked preflight before exempting unpaid liability retirement from the legacy guard" do
    item
    preview = PayrollRevisionPaymentPreflight.new(pay_period: period).ensure_eligible!
    expect {
      PayrollLiabilityPaymentGuard.ensure_clear!(pay_period: period, error_class: PayPeriodCorrectionService::InvalidStateError,
        action: "voiding", retirement_preflight: preview)
    }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /locked, successful/)
    locked = PayrollRevisionPaymentPreflight.new(pay_period: period, lock: true)
    expect { locked.retirement_payment_ids }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /locked, successful/)
    other_period = create(:pay_period, company: company)
    expect {
      PayrollLiabilityPaymentGuard.ensure_clear!(pay_period: other_period, error_class: PayPeriodCorrectionService::InvalidStateError,
        action: "voiding", retirement_preflight: locked)
    }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /belong to this payroll/)
  end
end
