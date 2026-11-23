# frozen_string_literal: true

module PayrollHistoryReview
  class Detector
    def initialize(company:, tax_year:)
      @company, @tax_year = company, tax_year
    end

    def call(apply: false, actor: Current.actor || AuditActor.system_job("Payroll history detection"))
      return scan unless apply

      @company.with_lock { scan(apply: true, actor: actor) }
    end

    private

    def scan(apply: false, actor: nil)
      counts = Hash.new(0)
      scope = PayrollHistoryReviewItem.where(company: @company, tax_year: @tax_year)
      existing = scope.index_by { |item| Subject.key_for(item) }
      results = subjects.map do |subject|
        item = existing[subject.key]
        if item.nil?
          counts[:new] += 1
          item = scope.new(subject.identity.merge(employee_id: subject.employee_id))
        elsif item.resolved? && item.subject_digest != subject.digest
          counts[:reopened] += 1
          Resolution.reopen_item!(item, reason: "Source evidence changed", actor: actor, digest: subject.digest) if apply
        else
          counts[item.resolved? ? :resolved : :open] += 1
        end

        if apply
          item.assign_attributes(subject_digest: subject.digest, employee_id: subject.employee_id)
          item.save! if item.changed?
        end
        [ item, subject ]
      end
      { counts: counts, items: results }
    end

    def subjects
      sources = Sources.new(company: @company, year: @tax_year)
      subjects = Subjects.new(sources)
      rules = PayrollFicaLegacyRecovery.new(company: @company, year: @tax_year).verified_year_rules if sources.imported_paychecks.exists?
      subjects.disputes + subjects.gaps + subjects.imports(rules: rules)
    end
  end
end
