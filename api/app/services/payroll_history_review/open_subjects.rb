# frozen_string_literal: true

module PayrollHistoryReview
  class OpenSubjects
    def initialize(company:, year:, excluding_pay_period_id: nil)
      @company, @year, @excluding_pay_period_id = company, year, excluding_pay_period_id
      @scope = PayrollHistoryReviewItem.where(company: company, tax_year: year, status: "resolved")
    end

    def call(subjects)
      resolved = matching_resolutions(subjects)
      subjects.reject { |subject| resolved.key?(subject.key) }
    end

    def matching_resolutions(subjects)
      return {} if subjects.empty?

      matches = subjects.group_by(&:type).reduce(@scope.none) do |relation, (type, group)|
        relation.or(@scope.where(subject_type: type, Subject::ID_COLUMNS.fetch(type) => group.map(&:id)))
      end
      resolved = matches.includes(:resolved_by).index_by { |item| Subject.key_for(item) }
      canonical_gaps = canonical_gaps_for(resolved)
      subjects.each_with_object({}) do |subject, result|
        item = resolved[subject.key]
        evidence = canonical_gaps.fetch(subject.key, subject)
        result[subject.key] = item if item && evidence.resolution_current?(item)
      end
    end

    private

    # The excluded paycheck is irrelevant to the current bound. If it is
    # already committed, it still belongs to the employee-year review digest.
    def canonical_gaps_for(resolved)
      employee_ids = resolved.values.filter_map { |item| item.employee_id if item.subject_type == "legacy_basis_gap" }
      return {} if employee_ids.empty? || !@excluding_pay_period_id
      return {} unless PayPeriod.where(id: @excluding_pay_period_id, company: @company, status: "committed").exists?

      sources = Sources.new(company: @company, year: @year, employee_ids: employee_ids)
      Subjects.new(sources).gaps.index_by(&:key)
    end
  end
end
