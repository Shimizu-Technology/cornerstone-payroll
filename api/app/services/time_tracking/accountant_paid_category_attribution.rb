# frozen_string_literal: true

module TimeTracking
  # A proposed accounting attribution, never a change to source categories or
  # payable REG/OT. Only the explicitly configured historical scope may use it.
  class AccountantPaidCategoryAttribution
    KIND = "accountant_attributed_paid_category"

    def initialize(source:, actor:)
      @source, @actor = source, actor
      @policies = TimeTrackingCategoryMapping.where(time_tracking_source: source, company_id: source.company_id).order(:id).to_a
      @cache = {}
    end

    def call(batch:, run:, mapping:, employee:, items:, run_checksum:, inventory_checksum:)
      key = [ batch.fetch("batch_id"), mapping.source_user_uuid, run.id, run_checksum, inventory_checksum ]
      return @cache[key] if @cache.key?(key)

      @cache[key] = build(batch, run, mapping, employee, items, run_checksum, inventory_checksum)
    end

    private

    def build(batch, run, mapping, employee, items, run_checksum, inventory_checksum)
      return if items.empty? || items.any? { |item| !item.payroll_included? || item.employee_id != mapping.employee_id || item.pay_period_id != run.id || item.company_id != @source.company_id }
      groups = employee.fetch("adjustments").group_by { |line| line["category"] }
      policies = groups.to_h do |category, _|
        [ category, @policies.find { |policy| policy.source_category_key == TimeTrackingCategoryMapping.category_key(category) && policy.historical_for?(mapping.employee_id, run.end_date, run_id: run.id) } ]
      end
      return unless policies.values.any?

      paid = paid_components(items)
      return unless paid
      source_total = groups.values.flatten.sum { |line| decimal(line.fetch("total_hours")) }
      paid_total = paid.values.sum { |component| component.fetch("hours") }
      difference = paid_total - source_total
      return if difference.abs > HistoricalRoundingReview::LIMIT

      remaining = paid.transform_values { |component| component.fetch("hours") }
      rows = []
      # Known categories consume their actual named component first. Only an
      # explicitly allowed uncategorized group may span the remaining components.
      ordered = groups.sort_by { |category, _| category.nil? ? 1 : 0 }
      ordered.each do |category, lines|
        hours = lines.sum { |line| decimal(line.fetch("total_hours")) }
        next if hours.zero?
        policy = policies[category]
        configured_labels = [ policy&.earning_label, policy&.fallback_earning_label ].compact_blank
        # Resolve the primary component before trying the fallback, regardless
        # of register row order. A fallback-only policy still constrains labels.
        matches = if configured_labels.any?
          configured_labels.lazy.map { |label| matching_components(paid, [ label ], policy: policy) }.find(&:any?) || []
        else
          matching_components(paid, [ category&.fetch("key", nil), category&.fetch("name", nil) ], policy: policy)
        end
        matches = paid.keys if policy && matches.empty? && paid.one? && configured_labels.empty?
        matches = remaining.select { |_, balance| balance.positive? }.keys.sort if policy && category.nil? && configured_labels.empty?
        return unless matches.any? && (policy || matches.one?)

        left = hours
        first_row = rows.length
        matches.each do |component|
          take = [ left, remaining.fetch(component) ].min
          next unless take.positive?
          rows << { "source_category" => category, "source_hours" => take.to_s("F"),
            "earning_component" => component, "paid_component" => paid.fetch(component).fetch("label"),
            "attributed_paid_hours" => take.to_s("F"), "rounding_difference" => "0.0" }
          remaining[component] -= take
          left -= take
        end
        # A bounded employee/run rounding difference is visible on this row;
        # it cannot be hidden by another employee or run.
        if left.positive? && left <= HistoricalRoundingReview::LIMIT && category == ordered.last.first && rows.any? && difference.negative?
          if rows.length == first_row
            rows << { "source_category" => category, "source_hours" => left.to_s("F"),
              "earning_component" => matches.first, "paid_component" => paid.fetch(matches.first).fetch("label"),
              "attributed_paid_hours" => "0.0", "rounding_difference" => (-left).to_s("F") }
          else
            rows.last["source_hours"] = (decimal(rows.last.fetch("source_hours")) + left).to_s("F")
            rows.last["rounding_difference"] = (-left).to_s("F")
          end
          left = 0.to_d
        end
        return unless left.zero?
      end
      if difference.positive?
        extra = remaining.select { |_, balance| balance.positive? }
        return unless extra.one? && rows.any? && extra.values.sole == difference
        row = rows.reverse.find { |candidate| candidate["earning_component"] == extra.keys.sole }
        return unless row
        row["attributed_paid_hours"] = (decimal(row.fetch("attributed_paid_hours")) + difference).to_s("F")
        row["rounding_difference"] = difference.to_s("F")
        remaining[extra.keys.sole] = 0.to_d
      end
      return unless remaining.values.all?(&:zero?) && rows.sum { |row| decimal(row.fetch("source_hours")) } == source_total

      { "type" => KIND, "source_instance_id" => @source.expected_source_instance_id,
        "batch_id" => batch.fetch("batch_id"), "batch_checksum" => batch.dig("export", "checksum"),
        "run_id" => run.id, "run_checksum" => run_checksum, "employee_id" => mapping.employee_id,
        "source_user_uuid" => mapping.source_user_uuid, "source_user_id" => mapping.source_user_id,
        "source_inventory_checksum" => inventory_checksum,
        "policies_checksum" => CanonicalPayload.checksum(@policies.map(&:attributes)),
        "source_total" => source_total.to_s("F"), "paid_total" => paid_total.to_s("F"),
        "signed_difference" => difference.to_s("F"), "rows" => rows,
        "reviewer_id" => @actor.id, "reviewer" => @actor.name,
        "reason" => "Accountant attributes retained source categories to the actual committed earning components",
        "evidence" => "Reviewed company historical scope, authenticated frozen lines and committed Payroll register; single history attestation" }
    rescue KeyError, ArgumentError, TypeError, NoMethodError
      nil
    end

    def paid_components(items)
      result = {}
      items.each do |item|
        earnings = item.payroll_item_earnings.select { |earning| earning.category.in?(%w[regular overtime]) }
        components = if earnings.any?
          earnings.map { |earning| [ "earning:#{earning.label}", earning.label, earning.category == "regular" ? "REG" : "OT", decimal(earning.hours) ] }
        elsif item.wage_rate_hours.any?
          item.wage_rate_hours.select { |row| row.fetch("active") }.flat_map do |row|
            HistoricalRoundingReview::PAY_CATEGORIES.map { |category, field| [ "wage_rate:#{row.fetch('employee_wage_rate_id')}", row.fetch("label"), category, decimal(row.fetch(field)) ] }
          end
        else
          [ [ "aggregate", "Regular", "REG", decimal(item.hours_worked) ], [ "aggregate", "Regular", "OT", decimal(item.overtime_hours) ] ]
        end
        return unless components.select { |row| row[2] == "REG" }.sum(&:last) == decimal(item.hours_worked) && components.select { |row| row[2] == "OT" }.sum(&:last) == decimal(item.overtime_hours)
        components.each do |identity, label, _, hours|
          result[identity] ||= { "label" => label, "hours" => 0.to_d }
          result[identity]["hours"] += hours
        end
      end
      result
    end

    def matching_components(paid, names, policy:)
      paid.keys.select do |component|
        paid_label = paid.fetch(component).fetch("label")
        names.compact.any? do |name|
          normalize(name) == normalize(paid_label) ||
            (policy && normalize(name) == "regular" && paid_label == "Regular Pay")
        end
      end
    end

    def normalize(value)
      TimeTrackingCategoryMapping.normalized(value).delete_prefix("aire ").delete_suffix(" hours")
    end

    def decimal(value)
      number = BigDecimal(value.to_s)
      raise ArgumentError unless number.finite? && number >= 0
      number
    end
  end
end
