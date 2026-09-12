# frozen_string_literal: true

module PayrollIntake
  class DispositionPlan
    Decision = Struct.new(:row, :disposition, :reason, :target_pay_period, :override, keyword_init: true) do
      def included?
        disposition == "included"
      end
    end

    def initialize(session:, row_overrides:, actor: nil)
      @session = session
      @row_overrides = Array(row_overrides)
      @actor = actor
    end

    def decisions
      @decisions ||= session.rows.in_order.map do |row|
        override = overrides_by_id[row.id.to_s] || overrides_by_position[row.position.to_s] || {}
        disposition = requested_disposition(override)
        target = target_pay_period_for(override, disposition)
        Decision.new(
          row: row,
          disposition: disposition,
          reason: override[:disposition_reason].to_s.strip.presence,
          target_pay_period: target,
          override: override
        )
      end
    end

    def validate!
      errors = override_validation_errors + decisions.flat_map { |decision| validation_errors(decision) }
      return self if errors.empty?

      raise ArgumentError, errors.join(" ")
    end

    def apply!(decision, status:, employee: nil, payroll_item: nil, staff_overrides: nil)
      decision.row.update!(
        disposition: decision.disposition,
        disposition_reason: decision.reason,
        target_pay_period: decision.target_pay_period,
        dispositioned_at: Time.current,
        dispositioned_by: actor,
        status: status,
        excluded: !decision.included?,
        employee: employee || decision.row.employee,
        applied_payroll_item: payroll_item,
        staff_overrides: staff_overrides || decision.override
      )
    end

    private

    attr_reader :session, :row_overrides, :actor

    def normalized_overrides
      @normalized_overrides ||= row_overrides.map do |override|
        data = override.respond_to?(:to_unsafe_h) ? override.to_unsafe_h : override.to_h
        data.deep_symbolize_keys
      end
    end

    def overrides_by_id
      @overrides_by_id ||= normalized_overrides.each_with_object({}) do |data, indexed|
        key = data[:id].presence || data[:row_id].presence
        indexed[key.to_s] = data if key.present?
      end
    end

    def overrides_by_position
      @overrides_by_position ||= normalized_overrides.each_with_object({}) do |data, indexed|
        indexed[data[:position].to_s] = data if data[:position].present?
      end
    end

    def override_validation_errors
      rows_by_id = session.rows.index_by { |row| row.id.to_s }
      rows_by_position = session.rows.index_by { |row| row.position.to_s }
      resolved_ids = []
      errors = normalized_overrides.filter_map do |data|
        row = if (key = data[:id].presence || data[:row_id].presence)
          rows_by_id[key.to_s]
        elsif data[:position].present?
          rows_by_position[data[:position].to_s]
        end
        if row
          resolved_ids << row.id
          nil
        else
          "A submitted source-row outcome does not belong to this payroll package."
        end
      end
      if resolved_ids.tally.values.any? { |count| count > 1 }
        errors << "Submit exactly one outcome for each source row."
      end
      errors.uniq
    end

    def requested_disposition(override)
      value = override[:disposition].to_s
      return value if value.present?
      return ActiveModel::Type::Boolean.new.cast(override[:include]) ? "included" : "excluded" if override.key?(:include)

      "pending"
    end

    def target_pay_period_for(override, disposition)
      return nil unless disposition == "deferred"

      target_id = override[:target_pay_period_id].presence
      return nil if target_id.blank?

      PayPeriod.find_by(id: target_id, company_id: session.company_id)
    end

    def validation_errors(decision)
      label = "#{decision.row.source_employee_name} (row #{decision.row.position + 1})"
      unless PayrollIntakeRow::DISPOSITIONS.include?(decision.disposition)
        return [ "Choose a valid outcome for #{label}." ]
      end
      return [ "Choose an outcome for #{label}; source rows cannot be left unchecked." ] if decision.disposition == "pending"
      if decision.disposition.in?(%w[excluded deferred informational]) && decision.reason.blank?
        return [ "Enter a reason for the #{decision.disposition} outcome on #{label}." ]
      end
      return [] unless decision.disposition == "deferred"

      target = decision.target_pay_period
      if target.blank? || target.id == session.pay_period_id || target.start_date <= session.pay_period.end_date ||
          !target.regular_cycle? || target.voided? || target.committed?
        return [ "Choose a future editable regular pay period for deferred #{label}." ]
      end

      []
    end
  end
end
