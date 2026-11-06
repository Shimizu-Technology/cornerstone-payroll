# frozen_string_literal: true

module TimeTracking
  # Accounting acknowledgement only. Never changes source hours or wages.
  class HistoricalRoundingReview
    LIMIT = BigDecimal("0.05")
    PAY_CATEGORIES = { "REG" => "regular_hours", "OT" => "overtime_hours" }.freeze

    attr_reader :variances, :blockers

    def initialize(source:, actor:, acknowledgements: [], component_bindings: [])
      @source, @actor = source, actor
      @acknowledgements, @bindings = acknowledgements, component_bindings
      @variances, @blockers, @known_bindings, @used_variances = {}, [], {}, {}
    end

    def verify!(batch:, run:, mapping:, source_employee:, items:, source_inventory_checksum:, run_checksum:, discover: false, policy_evidence: nil)
      raise ArgumentError, "Committed employee hours missing" if items.empty?

      base = {
        "source_instance_id" => @source.expected_source_instance_id,
        "batch_id" => batch.fetch("batch_id"), "batch_checksum" => batch.fetch("export").fetch("checksum"),
        "run_id" => run.id, "run_checksum" => run_checksum,
        "employee_mapping_id" => mapping.id, "employee_mapping_checksum" => CanonicalPayload.checksum(mapping.attributes),
        "employee_id" => mapping.employee_id, "source_user_id" => mapping.source_user_id,
        "source_user_uuid" => mapping.source_user_uuid, "source_inventory_checksum" => source_inventory_checksum
      }
      base["prior_overtime_policy"] = policy_evidence if policy_evidence
      groups = source_employee.fetch("adjustments").group_by { |line| line["category"] }
      paid = paid_components(items)
      aggregate = groups.length == 1 && PAY_CATEGORIES.keys.all? { |category| paid.values.count { |hours| hours.fetch(category).nonzero? } <= 1 }
      used = []
      results = groups.flat_map do |category, lines|
        PAY_CATEGORIES.map do |pay_category, field|
          source_total = lines.sum { |line| decimal(line.fetch(field)) }
          dimensions = base.merge("category" => pay_category, "source_category" => category)
          component = if aggregate
            paid.find { |_, hours| hours.fetch(pay_category).nonzero? }&.first || paid.keys.first || "aggregate"
          else
            binding = @bindings.is_a?(Array) && @bindings.find do |row|
              reviewed?(row, "historical_earning_component_binding") && dimensions.all? { |key, value| row[key] == value }
            end
            if binding && paid.key?(binding["earning_component"])
              @known_bindings[binding_key(dimensions)] = binding unless discover
              binding.fetch("earning_component")
            elsif source_total.zero? && paid.values.all? { |hours| hours.fetch(pay_category).zero? }
              next true
            else
              @blockers << dimensions.merge("reason" => "Reviewed one-to-one earning component binding required")
              next false
            end
          end
          # A paid component cannot cover two distinct source categories.
          identity = [ pay_category, component ]
          next false if used.include?(identity)

          used << identity
          paid_total = paid.fetch(component, { "REG" => 0.to_d, "OT" => 0.to_d }).fetch(pay_category)
          difference = paid_total - source_total
          next true if difference.zero?

          row = dimensions.merge("earning_component" => aggregate ? nil : component,
            "source_total" => source_total.to_s("F"), "paid_total" => paid_total.to_s("F"),
            "signed_difference" => difference.to_s("F"))
          @variances[variance_key(row)] = row
          @used_variances[variance_key(row)] = true unless discover
          discover || (difference.abs <= LIMIT && acknowledged?(row))
        end
      end
      # Unmatched paid dimensions cannot disappear or net against another one.
      accounted = paid.all? do |component, hours|
        hours.all? { |category, value| value.zero? || used.include?([ category, component ]) }
      end
      # A policy reclassification must preserve this employee's total exactly.
      # Category rounding still needs its individually signed acknowledgement.
      source_hours = source_employee.fetch("adjustments").sum { |line| decimal(line.fetch("total_hours")) }
      paid_hours = paid.values.sum { |hours| hours.values.sum }
      totals_tie = !policy_evidence || source_hours == paid_hours
      unless totals_tie
        @blockers << base.merge("reason" => "Prior-policy employee total differs from committed run",
          "source_total" => source_hours.to_s("F"), "paid_total" => paid_hours.to_s("F"))
      end
      results.all? && accounted && totals_tie
    rescue KeyError, ArgumentError, TypeError, NoMethodError => error
      @blockers << { "reason" => "Historical earning evidence invalid: #{error.message}" }
      false
    end

    def acknowledgements_valid?
      @acknowledgements.is_a?(Array) && @bindings.is_a?(Array) &&
        @acknowledgements.map { |row| variance_key(row) }.uniq.length == @acknowledgements.length &&
        @acknowledgements.all? { |row| @used_variances[variance_key(row)] && @variances[variance_key(row)]&.then { |actual| acknowledgement_matches?(row, actual) } } &&
        @bindings.map { |row| binding_key(row) }.uniq.length == @bindings.length &&
        @bindings.all? { |row| @known_bindings[binding_key(row)] == row }
    rescue KeyError, TypeError, NoMethodError
      false
    end

    def table
      variances.values.sort_by { |row| [ row.fetch("run_id"), row.fetch("employee_id"), row.fetch("category"), row["earning_component"].to_s ] }
        .map { |row| row.merge("within_limit" => decimal(row.fetch("signed_difference"), signed: true).abs <= LIMIT,
          "acknowledged" => acknowledged?(row)) }
    end

    private

    def paid_components(items)
      result = {}
      items.each do |item|
        raise ArgumentError, "Voided or reversed historical payroll item" unless item.payroll_included?

        earnings = item.payroll_item_earnings.select { |earning| earning.category.in?(%w[regular overtime]) }
        components = if earnings.any?
          earnings.map { |earning| [ "earning:#{earning.label}", earning.category == "regular" ? "REG" : "OT", decimal(earning.hours) ] }
        elsif item.wage_rate_hours.any?
          item.wage_rate_hours.select { |row| row.fetch("active") }.flat_map do |row|
            raise ArgumentError, "Historical wage component identity missing" if row["employee_wage_rate_id"].blank?

            PAY_CATEGORIES.map { |category, field| [ "wage_rate:#{row.fetch('employee_wage_rate_id')}", category, decimal(row.fetch(field)) ] }
          end
        else
          [ [ "aggregate", "REG", decimal(item.hours_worked) ], [ "aggregate", "OT", decimal(item.overtime_hours) ] ]
        end
        unless components.select { |_, category, _| category == "REG" }.sum(&:last) == decimal(item.hours_worked) &&
            components.select { |_, category, _| category == "OT" }.sum(&:last) == decimal(item.overtime_hours)
          raise ArgumentError, "Historical earning components do not reconcile to the payroll item"
        end
        components.each do |component, category, hours|
          result[component] ||= { "REG" => 0.to_d, "OT" => 0.to_d }
          result[component][category] += hours
        end
      end
      result
    end

    def acknowledged?(actual)
      @acknowledgements.is_a?(Array) && @acknowledgements.one? do |row|
        acknowledgement_matches?(row, actual)
      end
    end

    def acknowledgement_matches?(row, actual)
      reviewed?(row, "accountant_reviewed_rounding_variance") &&
        actual.except("source_total", "paid_total", "signed_difference").all? { |key, value| row[key] == value } &&
        %w[source_total paid_total signed_difference].all? do |key|
          decimal(row.fetch(key), signed: key == "signed_difference") == decimal(actual.fetch(key), signed: key == "signed_difference")
        end && decimal(actual.fetch("signed_difference"), signed: true).abs <= LIMIT
    rescue KeyError, ArgumentError, TypeError
      false
    end

    def reviewed?(row, type)
      row.is_a?(Hash) && row["type"] == type && row["reviewer_id"] == @actor.id &&
        %w[reason evidence].all? { |key| row[key].is_a?(String) && row[key].strip.length.between?(10, 2_000) }
    end

    def variance_key(row)
      row.values_at("run_id", "employee_mapping_id", "source_user_uuid", "employee_id", "batch_id", "category", "source_category", "earning_component")
    end

    def binding_key(row)
      row.values_at("run_id", "employee_mapping_id", "source_user_uuid", "employee_id", "batch_id", "category", "source_category")
    end

    def decimal(value, signed: false)
      number = BigDecimal(value.to_s)
      raise ArgumentError, "Hours must be finite" unless number.finite? && (signed || number >= 0)

      number
    end
  end
end
