# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollHistoryReview::Detector do
  include FicaHistoryHelpers

  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:actor) { create(:user, company: company) }
  let(:batch) { create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current) }
  let(:detector) { described_class.new(company: company, tax_year: 2026) }

  def period(year: 2026, **attrs)
    create(:pay_period, :committed, company: company, start_date: Date.new(year, 1, 1),
      end_date: Date.new(year, 1, 14), pay_date: Date.new(year, 1, 16), **attrs)
  end

  def paycheck(run = period, **attrs)
    bases = { fit_taxable_wages: 1000, social_security_taxable_wages: 1000, social_security_taxable_tips: 0,
      medicare_taxable_wages: 1000, additional_medicare_taxable_wages: 0 }
    create(:payroll_item, company: company, employee: employee, pay_period: run, gross_pay: 1000,
      social_security_tax: 62, employer_social_security_tax: 62, medicare_tax: 14.5, employer_medicare_tax: 14.5,
      **bases.merge(attrs))
  end

  def apply
    detector.call(apply: true)
  end

  it "detects all five subject types once and keeps dry runs read-only" do
    create(:tax_table, tax_year: 2026, ss_wage_base: 184500)
    original = paycheck(period(correction_status: "voided", void_reason: "Original payment cancelled"))
    replacement = paycheck(period(corrects_pay_period_id: original.pay_period_id))
    reversed = paycheck
    reversed.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: actor.id, payroll_reversal_reason: "Financial reversal")
    disposed = paycheck
    PayrollItemLegacyDisposition.insert_all!([ { payroll_item_id: disposed.id, company_id: company.id,
      created_by_id: actor.id, reason: "unreviewed_legacy_reason", evidence_digest: "a" * 64 } ])
    paycheck(additional_medicare_taxable_wages: nil)
    paycheck(social_security_taxable_wages: nil)
    imported

    expect { expect(detector.call.fetch(:counts)).to eq(new: 5) }.not_to change(PayrollHistoryReviewItem, :count)
    results = apply.fetch(:items)
    expect(results.map { |item, _subject| item.subject_type }).to contain_exactly(
      "voided_pay_period", "reversed_payroll_item", "legacy_disposition", "legacy_basis_gap", "imported_history")
    facts = results.find { |item, _subject| item.pay_period_id == original.pay_period_id }.last.facts
    expect(facts).to include("void_reason" => "Original payment cancelled", "gross_pay" => 1000.to_d,
      "replacements" => include(a_hash_including("id" => replacement.pay_period_id, "gross_pay" => 1000.to_d)))
    expect { expect(apply.fetch(:counts)).to eq(open: 5) }.not_to change(PayrollHistoryReviewItem, :count)
    expect(PayrollHistoryReviewItem.find_by!(subject_type: "legacy_basis_gap")).to have_attributes(employee_id: employee.id)
  end

  it "keeps companies and tax years isolated and detects nothing for clean payroll" do
    paycheck
    older = paycheck(period(year: 2025, correction_status: "voided"))
    other = create(:company)
    create(:pay_period, :voided, company: other, pay_date: Date.new(2026, 1, 16))

    expect(apply.fetch(:items)).to be_empty
    expect(PayrollHistoryReviewItem.count).to eq(0)
    old_items = described_class.new(company: company, tax_year: 2025).call(apply: true).fetch(:items).map(&:first)
    expect(old_items.sole).to have_attributes(company_id: company.id, tax_year: 2025, pay_period_id: older.pay_period_id)
  end

  it "does not create an imported review for reconciled imports on a verified annual path" do
    create(:tax_table, tax_year: 2026, ss_wage_base: 184500)
    paycheck
    row = imported
    EmployeeYearFicaSourceReview.record!(employee: employee, actor: actor, tax_year: 2026, through_pay_date: "2026-12-31",
      external_ss_wage_bound: 0, external_medicare_wage_bound: 0, review_reference: "Confirmed complete synthetic history")
    reconciliation = ImportedPaycheckFicaReconciliation.new(company: company, year: 2026)
    reconciliation.apply!(actor: actor, review_reference: "Reviewed synthetic import evidence",
      expected_digest: reconciliation.inventory.fetch(:plan_digest))
    expect(row.reload.fica_basis_proof).to be_present
    expect(apply.fetch(:items)).to be_empty
  end

  it "reopens a changed subject once and retains the original decision in the audit" do
    original = paycheck(period(correction_status: "voided", void_reason: "Original payment voided"))
    item = apply.fetch(:items).sole.first
    resolution = PayrollHistoryReview::Resolution.new(company: company, tax_year: 2026,
      subject_key: PayrollHistoryReview::Subject.key_for(item).join("-"), user: actor, actor: AuditActor.for_user(actor))
    original_digest = item.subject_digest
    resolution.resolve!(code: "void_reissued", reference: "Reissue evidence reviewed", expected_digest: original_digest)
    original.pay_period.update_columns(void_reason: "New evidence of cancellation")

    expect(detector.call.fetch(:counts)).to eq(reopened: 1)
    expect(item.reload).to be_resolved
    expect(apply.fetch(:counts)).to eq(reopened: 1)
    expect(apply.fetch(:counts)).to eq(open: 1)
    expect(item.reload).to have_attributes(status: "open", resolution_code: nil, resolved_at: nil)
    expect(item.subject_digest).not_to eq(original_digest)
    audit = AuditLog.find_by!(action: "payroll_history_review#reopen", record_id: item.id)
    expect(audit.metadata.fetch("previous_resolution")).to include("resolution_code" => "void_reissued",
      "resolved_by_id" => actor.id, "resolution_reference" => "Reissue evidence reviewed", "subject_digest" => original_digest)
  end
  it "ignores empty and contractor-only voids" do
    period(correction_status: "voided")
    paycheck(period(correction_status: "voided"), employment_type: "contractor")
    expect(apply.fetch(:items)).to be_empty
  end

  it "loads all matching replacement runs in one query and retains ID order" do
    first_void = paycheck(period(correction_status: "voided")).pay_period
    second_void = paycheck(period(correction_status: "voided", pay_date: Date.new(2026, 2, 2))).pay_period
    linked = paycheck(period(corrects_pay_period_id: first_void.id, pay_date: Date.new(2026, 2, 3))).pay_period
    same_dates = paycheck(period(source_pay_period_id: first_void.id)).pay_period
    second_match = paycheck(period(pay_date: second_void.pay_date)).pay_period
    queries = []
    observer = ->(_name, _start, _finish, _id, event) { queries << event[:sql] if event[:sql].include?("IS DISTINCT FROM 'voided'") }

    facts = ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      apply.fetch(:items).to_h { |item, subject| [ item.pay_period_id, subject.facts.fetch("replacements").pluck("id") ] }
    end

    expect(queries.size).to eq(1)
    expect(facts).to eq(first_void.id => [ linked.id, same_dates.id ], second_void.id => [ second_match.id ])
  end

  it "blocks detector writes in maintenance and sealed workspaces" do
    paycheck(period(correction_status: "voided"))
    allow(WriteMaintenance).to receive(:enabled?).and_return(true)
    expect { apply }.to raise_error(PayrollHistoryReview::Resolution::Maintenance)
    expect(detector.call.fetch(:counts)).to eq(new: 1)

    allow(WriteMaintenance).to receive(:enabled?).and_return(false)
    company.update_columns(test_workspace_sealed_at: Time.current)
    expect { apply }.to raise_error(PayrollHistoryReview::Resolution::Forbidden)
    expect(PayrollHistoryReviewItem.count).to eq(0)
  end

  it "auto-resolves a fully proven gap, then reopens if a new paycheck has only partial proof coverage" do
    create(:tax_table, tax_year: 2026, ss_wage_base: 184500)
    paycheck(social_security_taxable_wages: nil, additional_medicare_taxable_wages: nil, additional_medicare_tax: 0)
    item, subject = apply.fetch(:items).sole
    resolution = PayrollHistoryReview::Resolution.new(company: company, tax_year: 2026,
      subject_key: subject.route_key, user: actor, actor: AuditActor.for_user(actor))
    resolution.resolve!(code: "legacy_basis_accepted", reference: "Checked original statements", expected_digest: item.subject_digest)
    before_proofs = YearEnd::InputRevision.for(company.id, 2026)
    recovery = PayrollFicaLegacyRecovery.new(company: company, year: 2026)
    recovery.apply!(actor: actor, review_reference: "Checked archived FICA proof",
      expected_digest: recovery.inventory.fetch(:plan_digest))
    expect(YearEnd::InputRevision.for(company.id, 2026)).not_to eq(before_proofs)

    expect(detector.call.fetch(:items).sole.first).to have_attributes(status: "resolved",
      resolution_code: PayrollHistoryReviewItem::PROVEN_CODE, resolved_by_id: nil)
    expect(item.reload.resolution_code).to eq("legacy_basis_accepted")
    expect(apply.fetch(:counts)).to eq(proven: 1)
    expect(apply.fetch(:counts)).to eq(resolved: 1)
    expect(item.reload).to be_system_proven
    audit = AuditLog.where(record_id: item.id, action: "payroll_history_review#resolve").newest_first.first
    expect(audit).to have_attributes(actor_type: "system_job", actor_name: "Payroll history detection")
    expect(audit.metadata.dig("previous_resolution", "resolution_code")).to eq("legacy_basis_accepted")

    paycheck(additional_medicare_taxable_wages: nil)
    expect(apply.fetch(:counts)).to eq(reopened: 1)
    expect(item.reload).not_to be_resolved
  end
  it "requires manual review when a FICA proof leaves a missing W-2 wage base" do
    create(:tax_table, tax_year: 2026, ss_wage_base: 184500)
    row = paycheck(fit_taxable_wages: nil, social_security_taxable_wages: nil, additional_medicare_tax: 0)
    recovery = PayrollFicaLegacyRecovery.new(company: company, year: 2026)
    recovery.apply!(actor: actor, review_reference: "Checked archived FICA proof",
      expected_digest: recovery.inventory.fetch(:plan_digest))
    expect(row.reload.fica_basis_proof).to be_present
    warning = lambda do
      report = W2GuAggregator.new(company, 2026).generate
      YearEnd::JudgmentWarnings.new(company: company, year: 2026, w2_report: report).call.find { |entry| entry[:code] == "legacy_tax_bases" }
    end

    item, subject = apply.fetch(:items).sole
    expect(subject).not_to be_fully_proven
    expect(item).to have_attributes(status: "open", resolution_code: nil)

    # A proof resolution recorded before this check was introduced can still
    # match the digest. It cannot establish the missing FIT wages.
    item.update!(status: "resolved", resolution_code: PayrollHistoryReviewItem::PROVEN_CODE,
      resolution_reference: "Previously treated as fully proven", resolved_at: Time.current)
    expect(warning.call).to include(status: "needs_review")
    expect(detector.call.fetch(:items).sole.first).to have_attributes(status: "open")
    expect(item.reload).to be_resolved
    expect(apply.fetch(:counts)).to eq(reopened: 1)

    resolution = PayrollHistoryReview::Resolution.new(company: company, tax_year: 2026,
      subject_key: subject.route_key, user: actor, actor: AuditActor.for_user(actor))
    resolution.resolve!(code: "legacy_basis_accepted", reference: "Reviewed missing Guam taxable wages", expected_digest: subject.digest)
    expect(warning.call).to include(status: "reviewed")
    expect(apply.fetch(:counts)).to eq(resolved: 1)
  end
end
