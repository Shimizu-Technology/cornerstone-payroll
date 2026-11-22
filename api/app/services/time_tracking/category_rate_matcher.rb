# frozen_string_literal: true

module TimeTracking
  # Decides which Payroll earning a source category pays at. The cutoff import
  # and Pay late hours share it so the same hours can never resolve differently.
  class CategoryRateMatcher
    def initialize(source:, employee_ids: nil)
      @source = source
      return unless source.source_type == "aire_services"

      @policies = TimeTrackingCategoryMapping.where(time_tracking_source: source, import_enabled: true).index_by(&:source_category_key)
      if employee_ids
        @solo_choices = solo_choices.where(employee_id: employee_ids).index_by(&:employee_id)
      end
    end

    # Returns [rate, match_method, mapping_error].
    def call(category, rates, employee_id: nil)
      category = category.to_h.with_indifferent_access
      policy = @policies&.[](TimeTrackingCategoryMapping.category_key(category))
      if policy
        rate = policy.matching_rate(rates)
        return [ rate, "company_category_mapping", rate ? nil : "#{category[:name]} requires this employee's active #{policy.required_rate_description} rate; configure that rate before importing" ]
      end
      if source.source_type == "aire_services" && TimeTrackingEarningChoice.solo_category?(category)
        choice = @solo_choices ? @solo_choices[employee_id] : solo_choices.find_by(employee_id: employee_id)
        period_rate = choice && rates.find { |candidate| candidate.id == choice.employee_wage_rate_id }
        return choice&.matches_rate?(period_rate) ? [ period_rate, "accountant_choice" ] : [ nil, nil ]
      end
      candidates = [ category[:key], category[:name] ].compact_blank
      matches = labels_matching(rates, candidates) { |value| normalize(value) }
      # An earning named exactly like the category wins; "Hours" is only a fallback.
      matches = labels_matching(rates, candidates) { |value| normalize(value).delete_suffix(" hours") } if matches.empty?
      return [ matches.first, "label" ] if matches.one?

      [ nil, nil ]
    end

    private

    attr_reader :source

    def solo_choices
      TimeTrackingEarningChoice.where(time_tracking_source: source, source_category_key: "solo")
    end

    def labels_matching(rates, candidates)
      keys = candidates.map { |value| yield value }
      rates.select { |rate| keys.include?(yield(rate.label)) }
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end
  end
end
