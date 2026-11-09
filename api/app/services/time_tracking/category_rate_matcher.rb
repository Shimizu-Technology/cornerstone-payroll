# frozen_string_literal: true

module TimeTracking
  # Decides which Payroll earning a source category pays at. The cutoff import
  # and Pay late hours share it so the same hours can never resolve differently.
  class CategoryRateMatcher
    def initialize(source:)
      @source = source
    end

    # Returns [rate, match_method, mapping_error].
    def call(category, rates, employee_id: nil)
      category = category.to_h.with_indifferent_access
      policy = source.source_type == "aire_services" && TimeTrackingCategoryMapping.find_by(time_tracking_source: source,
        source_category_key: TimeTrackingCategoryMapping.category_key(category), import_enabled: true)
      if policy
        rate = policy.matching_rate(rates)
        return [ rate, "company_category_mapping", rate ? nil : "#{category[:name]} requires this employee's active #{policy.required_rate_description} rate; configure that rate before importing" ]
      end
      if source.source_type == "aire_services" && TimeTrackingEarningChoice.solo_category?(category)
        choice = TimeTrackingEarningChoice.find_by(time_tracking_source: source, employee_id: employee_id, source_category_key: "solo")
        rate = choice&.current_rate
        return rate && rates.any? { |candidate| candidate.id == rate.id } ? [ rate, "accountant_choice" ] : [ nil, nil ]
      end
      label_matches = rates.select do |rate|
        candidates = [ category[:key], category[:name] ].compact_blank.map { |value| normalize(value) }
        candidates.include?(normalize(rate.label))
      end
      return [ label_matches.first, "label" ] if label_matches.one?

      [ nil, nil ]
    end

    private

    attr_reader :source

    # "Ground Instruction" and "Ground Instruction Hours" name the same earning.
    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish.delete_suffix(" hours")
    end
  end
end
