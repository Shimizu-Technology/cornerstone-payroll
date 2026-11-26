# frozen_string_literal: true

# Records whether an overlapping native paycheck is its own payment or a
# duplicate of an imported one (PayrollBridgeOverlap). An unambiguous
# evidence proposal can be recorded as is; anything else takes a staff
# decision with a reason. Either way the evidence must still be what was
# reviewed, and the employee's later stubs are rechecked: a stub revises only
# if a printed figure actually moved.
class PayrollBridgeOverlapDispositionService
  class Error < StandardError; end

  # Records every pending overlap whose evidence is unambiguous. Ambiguous
  # ones stay pending for staff review. Returns the new dispositions.
  def self.record_evident!(company_id:, year:, actor:)
    authorize!(actor, company_id)
    PayrollBridgeOverlap.new(company_id: company_id, year: year).pending.reject { |overlap| overlap.proposal == :ambiguous }.map do |overlap|
      record!(overlap, decision: overlap.proposal == :duplicate ? PayrollItemBridgeOverlapDisposition::DUPLICATE : PayrollItemBridgeOverlapDisposition::DISTINCT,
        historical_paycheck_id: overlap.matched_paycheck_id, source: "payment_evidence", actor: actor,
        reason: overlap.proposal == :duplicate ? "Same pay date, gross, net and check number as imported paycheck ##{overlap.matched_paycheck_id}" : "No imported paycheck shares its pay date, check number or amounts")
    end
  end

  # A staff decision for one overlap, against the evidence they reviewed.
  def self.decide!(payroll_item:, historical_import_batch_id:, decision:, actor:, reason:, evidence_digest:, historical_paycheck_id: nil)
    authorize!(actor, payroll_item.company_id)
    raise Error, "Give a reason for the decision" if reason.to_s.strip.empty?

    overlap = PayrollBridgeOverlap.new(company_id: payroll_item.company_id, year: payroll_item.pay_period.pay_date.year,
      employee_ids: [ payroll_item.employee_id ]).call
      .find { |row| row.payroll_item.id == payroll_item.id && row.batch_id == Integer(historical_import_batch_id) }
    raise Error, "Paycheck ##{payroll_item.id} doesn't overlap that import's opening balance" unless overlap
    raise Error, "Paycheck ##{payroll_item.id} already has a recorded decision" unless overlap.pending?
    raise Error, "The payment evidence changed after review; review it again" unless overlap.evidence_digest == evidence_digest

    record!(overlap, decision: decision, historical_paycheck_id: historical_paycheck_id, source: "staff_review", actor: actor, reason: reason)
  end

  def self.authorize!(actor, company_id)
    return if actor&.persisted? && actor.active? && actor.staff_member? && actor.can_access_company?(Integer(company_id))

    raise Error, "An authorized payroll staff actor is required"
  end
  private_class_method :authorize!

  def self.record!(overlap, decision:, historical_paycheck_id:, source:, actor:, reason:)
    item = overlap.payroll_item
    ApplicationRecord.transaction do
      Company.lock.find(item.company_id)
      disposition = PayrollItemBridgeOverlapDisposition.create!(
        company_id: item.company_id, payroll_item: item, historical_import_batch_id: overlap.batch_id,
        historical_paycheck_id: decision == PayrollItemBridgeOverlapDisposition::DUPLICATE ? historical_paycheck_id : nil,
        decision: decision, source: source, created_by: actor, reason: reason.to_s.strip,
        evidence: overlap.evidence, evidence_digest: overlap.evidence_digest
      )
      AuditLog.record!(user: actor, organization_id: item.company.organization_id, company_id: item.company_id,
        action: "payroll_item#bridge_overlap_disposition",
        record_type: "payroll_items", record_id: item.id,
        metadata: { decision: decision, source: source, historical_import_batch_id: overlap.batch_id,
                    historical_paycheck_id: disposition.historical_paycheck_id, evidence_digest: disposition.evidence_digest })
      recheck_stubs!(item)
      disposition
    end
  end
  private_class_method :record!

  # The decision moves this employee's statement YTD from this paycheck on.
  def self.recheck_stubs!(item)
    date = item.pay_period.pay_date
    ids = PayrollItem.where(company_id: item.company_id, employee_id: item.employee_id)
      .joins(:pay_period).where(pay_periods: { pay_date: date..Date.new(date.year, 12, 31) }).pluck(:id)
    PayrollYtdSnapshotRefresh.mark_stubs_due!(ids)
  end
  private_class_method :recheck_stubs!
end
