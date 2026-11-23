# frozen_string_literal: true

module PayrollHistoryReview
  class OpenSubjects
    def initialize(company:, year:)
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
      subjects.each_with_object({}) do |subject, result|
        item = resolved[subject.key]
        result[subject.key] = item if item && item.subject_digest == subject.digest
      end
    end
  end
end
