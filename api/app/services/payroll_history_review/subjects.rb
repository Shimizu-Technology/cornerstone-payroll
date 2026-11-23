# frozen_string_literal: true

module PayrollHistoryReview
  class Subjects
    def initialize(sources)
      @sources = sources
    end

    def disputes
      @disputes ||= voided_subjects +
        paycheck_subjects("reversed_payroll_item", @sources.reversals) +
        paycheck_subjects("legacy_disposition", @sources.legacy_dispositions)
    end

    # The checklist covers both systems. W-2 compatibility also checks FIT and
    # Medicare and may report missing stored fields even when FICA has proof.
    # FICA additionally checks the Additional Medicare base and only uses its
    # pre-existing unverified-row predicate to decide whether it needs a bound.
    def gaps
      @gaps ||= begin
        fica_ids = @sources.unverified_legacy.pluck(:id).to_set
        w2_ids = @sources.w2_missing_bases.pluck(:id).to_set
        proof_ids = @sources.proof_backed_legacy.pluck(:id)
        rows = PayrollItem.where(id: (fica_ids | w2_ids | proof_ids).to_a).includes(:employee, :pay_period, :legacy_disposition, :fica_basis_proof,
          { payroll_item_field_entries: :payroll_field_definition }, payroll_item_deductions: :deduction_type).order(:id)
        rows.group_by(&:employee_id).map do |employee_id, checks|
          Subject.new("legacy_basis_gap", employee_id, checks, employee_id: employee_id, fica_ids: fica_ids, w2_ids: w2_ids)
        end
      end
    end

    def imports(rules:)
      rules ? imports_for_batches(@sources.disputed_import_batch_ids(rules)) : []
    end

    # Used only after the paycheck's actual ordinary calculation failed.
    def imports_for_batches(batch_ids)
      return [] if batch_ids.empty?

      @sources.import_batches(batch_ids).map { |batch_id, rows| Subject.new("imported_history", batch_id, rows) }
    end

    private

    def voided_subjects
      voids = @sources.voided_periods.order(:id).to_a
      replacements = @sources.replacements_for(voids)
      voids.map { |period| Subject.new("voided_pay_period", period.id, [ period ], replacements: replacements.fetch(period.id)) }
    end

    def paycheck_subjects(type, rows)
      rows.order(:id).map { |row| Subject.new(type, row.id, [ row ], employee_id: row.employee_id) }
    end
  end
end
