# frozen_string_literal: true

module PayrollIntake
  class ApplyService
    def initialize(session:, row_overrides: [], actor: nil, force_overwrite: false, acknowledge_warnings: false)
      @session = session
      @pay_period = session.pay_period
      @company = session.company
      @row_overrides = Array(row_overrides)
      @actor = actor
      @force_overwrite = force_overwrite
      @acknowledge_warnings = ActiveModel::Type::Boolean.new.cast(acknowledge_warnings)
    end

    def call
      raise ArgumentError, "Cannot apply to a non-editable pay period" unless pay_period.can_edit?
      raise ArgumentError, "Only previewed payroll intake sessions can be applied" unless session.applyable?

      results = { applied: [], skipped: [], errors: [] }
      overrides_by_key = build_overrides_by_key
      excluded_employee_ids = pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set

      ActiveRecord::Base.transaction do
        session.with_lock do
          session.rows.includes(:employee).each do |row|
            override = overrides_by_key[row.id.to_s] || overrides_by_key[row.position.to_s] || {}
            include_row = include_row?(override)
            unless include_row
              row.update!(status: "skipped", excluded: true)
              results[:skipped] << { row_id: row.id, source_employee_name: row.source_employee_name, reason: "excluded" }
              next
            end

            if row.warnings_payload.any? && !acknowledged?(override)
              results[:errors] << { row_id: row.id, source_employee_name: row.source_employee_name, error: "Review or acknowledge row warnings before applying." }
              next
            end

            employee = employee_for(row, override)
            unless employee
              results[:errors] << { row_id: row.id, source_employee_name: row.source_employee_name, error: "Employee mapping required" }
              next
            end

            if excluded_employee_ids.include?(employee.id)
              row.update!(status: "skipped", excluded: true, employee: employee)
              results[:skipped] << { row_id: row.id, employee_id: employee.id, source_employee_name: row.source_employee_name, reason: "Excluded from this pay period" }
              next
            end

            values = values_for(row, override)
            if values[:tips_paid_out].positive? && values[:reported_tips] < values[:tips_paid_out]
              values[:reported_tips] = values[:tips_paid_out]
            end

            payroll_item = pay_period.payroll_items.lock.find_or_initialize_by(employee_id: employee.id)
            overwrite_error = overwrite_error_for(payroll_item)
            if overwrite_error
              results[:errors] << { row_id: row.id, employee_id: employee.id, source_employee_name: row.source_employee_name, error: overwrite_error }
              next
            end

            if employee.variable_salary? && payroll_item.salary_override.to_f <= 0
              results[:errors] << { row_id: row.id, employee_id: employee.id, source_employee_name: row.source_employee_name, error: "Enter this employee's variable salary amount before applying payroll intake." }
              next
            end

            apply_values!(payroll_item, employee, values)
            row.update!(
              employee: employee,
              applied_payroll_item: payroll_item,
              status: "applied",
              excluded: false,
              staff_overrides: override
            )

            results[:applied] << {
              row_id: row.id,
              employee_id: employee.id,
              employee_name: employee.full_name,
              regular_hours: payroll_item.hours_worked.to_f,
              overtime_hours: payroll_item.overtime_hours.to_f,
              reported_tips: payroll_item.reported_tips.to_f,
              tips_paid_out: payroll_item.tips_paid_out.to_f
            }
          rescue ActiveRecord::RecordInvalid => e
            results[:errors] << { row_id: row.id, source_employee_name: row.source_employee_name, error: e.message }
          end

          raise ActiveRecord::Rollback if results[:errors].any?

          session.mark_reviewed!(actor: actor) if session.status == "previewed"
          session.mark_applied!(actor: actor)
        end
      end

      if results[:errors].empty? && results[:applied].any?
        pay_period.update!(
          status: "calculated",
          calculated_at: Time.current,
          calculated_by_id: actor&.id,
          approved_at: nil,
          approved_by_id: nil,
          unapproved_at: nil,
          unapproved_by_id: nil
        )
      end

      results
    end

    private

    attr_reader :session, :pay_period, :company, :row_overrides, :actor, :force_overwrite, :acknowledge_warnings

    def build_overrides_by_key
      row_overrides.each_with_object({}) do |override, acc|
        data = override.respond_to?(:to_unsafe_h) ? override.to_unsafe_h : override.to_h
        data = data.deep_symbolize_keys
        key = data[:id].presence || data[:row_id].presence || data[:position].presence
        next if key.blank?

        acc[key.to_s] = data
      end
    end

    def include_row?(override)
      return true unless override.key?(:include)

      ActiveModel::Type::Boolean.new.cast(override[:include])
    end

    def acknowledged?(override)
      acknowledge_warnings || ActiveModel::Type::Boolean.new.cast(override[:acknowledge_warnings])
    end

    def employee_for(row, override)
      employee_id = override[:employee_id].presence || row.employee_id
      return nil if employee_id.blank?

      Employee.active.find_by(id: employee_id, company_id: company.id)
    end

    def values_for(row, override)
      {
        regular_hours: decimal_override(override, :regular_hours, row.regular_hours),
        overtime_hours: decimal_override(override, :overtime_hours, row.overtime_hours),
        week1_hours: decimal_override(override, :week1_hours, row.week1_hours),
        week2_hours: decimal_override(override, :week2_hours, row.week2_hours),
        week1_tips: decimal_override(override, :week1_tips, row.week1_tips),
        week2_tips: decimal_override(override, :week2_tips, row.week2_tips),
        reported_tips: decimal_override(override, :reported_tips, row.reported_tips),
        tips_paid_out: decimal_override(override, :tips_paid_out, row.tips_paid_out),
        loan_deduction: decimal_override(override, :loan_deduction, row.loan_deduction)
      }
    end

    def decimal_override(override, key, fallback)
      value = override.key?(key) ? override[key] : fallback
      BigDecimal(value.to_s.presence || "0").round(2).to_f
    rescue ArgumentError
      0.0
    end

    def overwrite_error_for(payroll_item)
      return nil unless payroll_item.persisted?
      return nil if force_overwrite
      return nil if payroll_item.import_source == session.source_type

      "Payroll item already exists from another source or manual entry. Use force overwrite only after review."
    end

    def apply_values!(payroll_item, employee, values)
      if payroll_item.new_record?
        payroll_item.company_id = company.id
        payroll_item.employment_type = employee.employment_type
        payroll_item.additional_withholding = employee.additional_withholding.to_f
      end

      payroll_item.clear_wage_rate_hours!
      payroll_item.employment_type = employee.employment_type
      payroll_item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
      payroll_item.hours_worked = values[:regular_hours]
      payroll_item.overtime_hours = values[:overtime_hours]
      payroll_item.reported_tips = values[:reported_tips]
      payroll_item.tips_paid_out = values[:tips_paid_out]
      payroll_item.tips = 0.0 if payroll_item.respond_to?(:tips=)
      payroll_item.loan_deduction = values[:loan_deduction]
      payroll_item.import_source = session.source_type
      payroll_item.apply_default_payroll_adjustments_if_unset!(employee)
      payroll_item.calculate!
    end
  end
end
