# frozen_string_literal: true

require_relative "../rls_task"

# Native paychecks dated inside an imported opening balance (PayrollBridgeOverlap).
namespace :payroll do
  namespace :bridge_overlaps do
    desc "Print a read-only list of overlapping native paychecks and their payment evidence (COMPANY_ID, YEAR required)"
    RlsTask.system preview: :environment do
      overlaps = PayrollBridgeOverlap.new(company_id: Integer(ENV.fetch("COMPANY_ID")), year: Integer(ENV.fetch("YEAR"))).call
      puts JSON.pretty_generate(overlaps.map do |overlap|
        {
          payroll_item_id: overlap.payroll_item.id, historical_import_batch_id: overlap.batch_id,
          proposal: overlap.proposal, matched_historical_paycheck_id: overlap.matched_paycheck_id,
          recorded: overlap.disposition&.decision, evidence_digest: overlap.evidence_digest, evidence: overlap.evidence
        }
      end)
    end

    desc "Record every overlap whose payment evidence is unambiguous (COMPANY_ID, YEAR, ACTOR_ID required)"
    RlsTask.system record_evident: :environment do
      result = PayrollBridgeOverlapDispositionService.record_evident!(company_id: Integer(ENV.fetch("COMPANY_ID")),
        year: Integer(ENV.fetch("YEAR")), actor: User.find(Integer(ENV.fetch("ACTOR_ID"))))
      puts JSON.pretty_generate(result.map { |row| { payroll_item_id: row.payroll_item_id, decision: row.decision, disposition_id: row.id } })
    end

    desc "Record a staff decision (PAYROLL_ITEM_ID, BATCH_ID, DECISION=distinct|duplicate_of_imported, EVIDENCE_DIGEST, REASON, ACTOR_ID; HISTORICAL_PAYCHECK_ID for a duplicate)"
    RlsTask.system decide: :environment do
      row = PayrollBridgeOverlapDispositionService.decide!(
        payroll_item: PayrollItem.find(Integer(ENV.fetch("PAYROLL_ITEM_ID"))),
        historical_import_batch_id: Integer(ENV.fetch("BATCH_ID")), decision: ENV.fetch("DECISION"),
        evidence_digest: ENV.fetch("EVIDENCE_DIGEST"), reason: ENV.fetch("REASON"),
        historical_paycheck_id: ENV["HISTORICAL_PAYCHECK_ID"].presence&.then { |id| Integer(id) },
        actor: User.find(Integer(ENV.fetch("ACTOR_ID")))
      )
      puts JSON.pretty_generate(payroll_item_id: row.payroll_item_id, decision: row.decision, disposition_id: row.id)
    end
  end
end
