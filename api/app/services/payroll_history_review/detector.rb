# frozen_string_literal: true

module PayrollHistoryReview
  class Detector
    def initialize(company:, tax_year:)
      @company, @tax_year = company, tax_year
    end

    def call(apply: false, required_key: nil)
      return scan unless apply

      Resolution.ensure_writable!(@company)
      @company.with_lock do
        Resolution.ensure_writable!(@company)
        scan(apply: true, required_key: required_key)
      end
    end

    private

    def scan(apply: false, required_key: nil)
      counts = Hash.new(0)
      scope = PayrollHistoryReviewItem.where(company: @company, tax_year: @tax_year)
      existing = scope.includes(:resolved_by).index_by { |item| Subject.key_for(item) }
      detected = subjects
      raise ActiveRecord::RecordNotFound if required_key && detected.none? { |subject| subject.route_key == required_key }

      results = detected.map do |subject|
        item = existing[subject.key] || scope.new(subject.identity.merge(employee_id: subject.employee_id))
        counts[reconcile(item, subject, apply: apply)] += 1
        [ item, subject ]
      end
      { counts: counts, items: results }
    end

    def reconcile(item, subject, apply:)
      matching = item.subject_digest == subject.digest
      if subject.fully_proven? && !(item.resolved? && item.resolution_code == PayrollHistoryReviewItem::PROVEN_CODE && matching)
        Resolution.prove_item(item, digest: subject.digest, at: subject.proven_at, apply: apply)
        return :proven
      end

      if item.resolved? && !matching
        Resolution.reopen_item(item, reason: "Source evidence changed", actor: Resolution.detection_actor, digest: subject.digest, apply: apply)
        count = :reopened
      else
        count = item.new_record? ? :new : item.status.to_sym
      end
      item.assign_attributes(subject_digest: subject.digest, employee_id: subject.employee_id)
      item.save! if apply && item.changed?
      count
    end

    def subjects
      sources = Sources.new(company: @company, year: @tax_year)
      subjects = Subjects.new(sources)
      rules = PayrollFicaLegacyRecovery.new(company: @company, year: @tax_year).verified_year_rules if sources.imported_paychecks.exists?
      subjects.disputes + subjects.gaps + subjects.imports(rules: rules)
    end
  end
end
