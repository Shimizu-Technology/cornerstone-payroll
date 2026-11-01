# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriod, "deletion", type: :model do
  it "cleans up all revisions of an unapproved source package without allowing direct evidence deletion" do
    period = create(:pay_period, status: "calculated")
    first = create(:payroll_intake_session, pay_period: period, company: period.company, package_revision: 1)
    first.mark_superseded!
    second = create(:payroll_intake_session, pay_period: period, company: period.company, status: "draft", supersedes: first,
      package_revision: 2, supersession_reason: "Corrected synthetic hours")
    document = second.documents.create!(document_type: "pasted_text", text_content: "Synthetic hours")

    expect(document.destroy).to be(false)
    expect(second.destroy).to be(false)
    expect(period.destroy).to be_truthy
    expect(PayrollIntakeSession.where(id: [ first.id, second.id ])).to be_empty
    expect(PayrollIntakeDocument.exists?(document.id)).to be(false)
  end

  it "does not delete a run that was previously committed even if it is labelled draft" do
    period = create(:pay_period)
    period.update_column(:committed_at, Time.current)
    expect(period.destroy).to be(false)
    expect(period.errors.full_messages.to_sentence).to include("never been committed")
  end

  it "retains a run approved then unapproved, including after recalculation is invalidated" do
    period = create(:pay_period, :approved, approved_at: 1.hour.ago)
    session = create(:payroll_intake_session, pay_period: period, company: period.company)
    PayPeriodLifecycleService.new(pay_period: period, actor: nil).unapprove!
    period.invalidate_calculation!(reason: "Correct hours")

    expect(period.reload.destroy).to be(false)
    expect(period.errors.full_messages).to include("This run was approved before. Keep it and correct it instead, or ask an admin.")
    expect(PayrollIntakeSession.exists?(session.id)).to be(true)
  end

  it "retains a run with historical approval audit evidence even when timestamps are absent" do
    period = create(:pay_period, :calculated)
    AuditLog.record!(company_id: period.company_id, action: "pay_periods#approve", record_type: "pay_periods", record_id: period.id)

    expect(period.destroy).to be(false)
    expect(period.errors.full_messages.to_sentence).to include("approved before")
  end

  it "retains deferred hours and names their later target run" do
    period = create(:pay_period, :calculated)
    target = create(:pay_period, company: period.company, start_date: "2024-01-15", end_date: "2024-01-28", pay_date: "2024-02-02")
    session = create(:payroll_intake_session, pay_period: period, company: period.company)
    row = create(:payroll_intake_row, payroll_intake_session: session, disposition: "deferred",
      target_pay_period: target, dispositioned_at: Time.current, disposition_reason: "Carry to next run")

    expect(period.destroy).to be(false)
    expect(period.errors.full_messages.to_sentence).to include("run ##{target.id}", "2024-01-15 to 2024-01-28")
    expect(row.reload.target_pay_period).to eq(target)
    expect(PayrollIntakeSession.exists?(session.id)).to be(true)
  end

  it "rolls back the entire destroy chain when a calculated item has a restricted child" do
    period = create(:pay_period, :calculated)
    session = create(:payroll_intake_session, pay_period: period, company: period.company, status: "draft")
    document = session.documents.create!(document_type: "pdf", storage_reference: "synthetic/rollback.pdf")
    item = create(:payroll_item, pay_period: period, company: period.company, employee: create(:employee, company: period.company))
    row = create(:payroll_intake_row, payroll_intake_session: session, employee: item.employee, applied_payroll_item: item)
    proof = PayrollItemFicaBasisProof.create!(payroll_item: item, company: period.company, created_by: create(:user),
      review_reference: "Synthetic reviewed proof", plan_digest: "a" * 64, tax_year: period.pay_date.year, evidence: { "reviewed" => true })
    expect(R2StorageService).not_to receive(:new)

    expect { period.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
    expect(PayPeriod.exists?(period.id)).to be(true)
    expect(PayrollIntakeSession.exists?(session.id)).to be(true)
    expect(PayrollIntakeDocument.exists?(document.id)).to be(true)
    expect(PayrollIntakeRow.exists?(row.id)).to be(true)
    expect(PayrollItem.exists?(item.id)).to be(true)
    expect(PayrollItemFicaBasisProof.exists?(proof.id)).to be(true)
  end
end
