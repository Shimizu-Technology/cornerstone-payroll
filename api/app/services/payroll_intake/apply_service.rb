# frozen_string_literal: true

require "set"

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

      ActiveRecord::Base.transaction do
        pay_period.with_lock do
          raise ArgumentError, "Cannot apply to a non-editable pay period" unless pay_period.can_edit?

          excluded_employee_ids = pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set

          session.with_lock(requires_new: true) do
            raise ArgumentError, "Only previewed payroll intake sessions can be applied" unless session.applyable?
            PayrollIntake::WorkweekEvidence.new(pay_period: pay_period).validate_snapshot!(
              session.evidence_snapshot.to_h["workweek"]
            )

            rows = session.rows.includes(:employee).to_a
            duplicate_employee_ids = duplicate_employee_ids_for(rows, overrides_by_key, excluded_employee_ids)

            rows.each do |row|
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

              if duplicate_employee_ids.include?(employee.id)
                results[:errors] << { row_id: row.id, employee_id: employee.id, source_employee_name: row.source_employee_name, error: "Multiple included intake rows map to #{employee.full_name}. Exclude or remap duplicates before applying." }
                next
              end

              unresolved_errors = unresolved_validation_errors(row, override, employee)
              if unresolved_errors.any?
                results[:errors] << {
                  row_id: row.id,
                  employee_id: employee.id,
                  source_employee_name: row.source_employee_name,
                  error: unresolved_errors.join(" ")
                }
                next
              end

              values = validated_values_for(row, override)
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
                staff_overrides: override,
                week1_hours: values[:week1_hours],
                week2_hours: values[:week2_hours],
                regular_hours: values[:regular_hours],
                overtime_hours: values[:overtime_hours],
                week1_tips: values[:week1_tips],
                week2_tips: values[:week2_tips],
                reported_tips: values[:reported_tips],
                tips_paid_out: values[:tips_paid_out],
                loan_deduction: values[:loan_deduction],
                validation_errors: []
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
            rescue ActiveRecord::RecordInvalid, ArgumentError => e
              results[:errors] << { row_id: row.id, source_employee_name: row.source_employee_name, error: e.message }
            end

            raise ActiveRecord::Rollback if results[:errors].any?

            update_pay_period_after_apply! if results[:applied].any?
            session.mark_reviewed!(actor: actor) if session.status == "previewed"
            session.mark_applied!(actor: actor)
          end
        end
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

    def duplicate_employee_ids_for(rows, overrides_by_key, excluded_employee_ids)
      mapped_employee_ids = rows.filter_map do |row|
        override = overrides_by_key[row.id.to_s] || overrides_by_key[row.position.to_s] || {}
        next unless include_row?(override)

        employee = employee_for(row, override)
        next if employee.blank? || excluded_employee_ids.include?(employee.id)

        employee.id
      end

      mapped_employee_ids.tally.select { |_employee_id, count| count > 1 }.keys.to_set
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

    def validated_values_for(row, override)
      values = values_for(row, override)
      weekly_total = values.fetch(:week1_hours) + values.fetch(:week2_hours)
      if values.fetch(:week1_hours) > 168 || values.fetch(:week2_hours) > 168
        raise ArgumentError, "Week 1 and Week 2 hours cannot exceed 168 hours"
      end
      unless reconciles?(weekly_total, row.total_hours)
        raise ArgumentError, "Week 1 + Week 2 hours must equal the extracted row total of #{format('%.2f', row.total_hours)} hours"
      end

      regular_hours, overtime_hours = PayrollIntake::Adapters::SpikeEmail.split_for_weekly_hours(
        values.fetch(:week1_hours),
        values.fetch(:week2_hours)
      )
      unless reconciles?(values.fetch(:regular_hours), regular_hours) && reconciles?(values.fetch(:overtime_hours), overtime_hours)
        raise ArgumentError,
              "Regular/overtime overrides must match Payroll's legal weekly calculation " \
              "(#{format('%.2f', regular_hours)} regular / #{format('%.2f', overtime_hours)} overtime)"
      end

      values.merge(regular_hours: regular_hours, overtime_hours: overtime_hours)
    end

    def unresolved_validation_errors(row, override, employee)
      Array(row.errors_payload).filter_map do |payload|
        error = payload.respond_to?(:with_indifferent_access) ? payload.with_indifferent_access : {}
        code = error[:code].to_s
        next if code == "unmatched_employee" && employee.present?
        next if code.in?(%w[weekly_hours_required incomplete_weekly_hours]) && repaired_weekly_hours?(row, override)

        error[:message].presence || "Resolve the stored payroll intake validation error before applying."
      end
    end

    def repaired_weekly_hours?(row, override)
      return false unless override.key?(:week1_hours) && override.key?(:week2_hours)

      week1 = decimal_override(override, :week1_hours, row.week1_hours)
      week2 = decimal_override(override, :week2_hours, row.week2_hours)
      reconciles?(week1 + week2, row.total_hours)
    end

    def decimal_override(override, key, fallback)
      value = override.key?(key) ? override[key] : fallback
      number = BigDecimal(value.to_s, exception: false)
      raise ArgumentError, "#{key.to_s.humanize} must be a finite non-negative number" unless number&.finite? && !number.negative?

      number.round(2).to_f
    end

    def reconciles?(left, right)
      (BigDecimal(left.to_s) - BigDecimal(right.to_s)).abs <= BigDecimal("0.01")
    end

    def overwrite_error_for(payroll_item)
      return nil unless payroll_item.persisted?
      return nil if force_overwrite
      return nil if payroll_item.import_source == session.source_type

      "Payroll item already exists from another source or manual entry. Use force overwrite only after review."
    end

    def update_pay_period_after_apply!
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

    def apply_values!(payroll_item, employee, values)
      prepare_payroll_item_for_intake!(payroll_item, employee)

      payroll_item.hours_worked = values[:regular_hours]
      payroll_item.overtime_hours = values[:overtime_hours]
      payroll_item.reported_tips = values[:reported_tips]
      payroll_item.tips_paid_out = values[:tips_paid_out]
      payroll_item.tips = 0.0 if payroll_item.respond_to?(:tips=)
      persist_tip_components!(payroll_item, values)
      payroll_item.loan_deduction = values[:loan_deduction]
      payroll_item.import_source = session.source_type
      payroll_item.sync_default_payroll_adjustments!(employee)
      payroll_item.calculate!
    end

    def persist_tip_components!(payroll_item, values)
      components = [
        { "label" => "Tips 1", "amount" => values[:week1_tips].to_f.round(2) },
        { "label" => "Tips 2", "amount" => values[:week2_tips].to_f.round(2) }
      ].select { |component| component["amount"].positive? }

      data = payroll_item.custom_columns_data.is_a?(Hash) ? payroll_item.custom_columns_data.deep_dup : {}
      if components.any?
        data["tip_components"] = components
      else
        data.delete("tip_components")
        data.delete(:tip_components)
      end
      payroll_item.custom_columns_data = data
    end

    def prepare_payroll_item_for_intake!(payroll_item, employee)
      if payroll_item.new_record?
        payroll_item.company_id = company.id
      else
        reset_stale_intake_item_fields!(payroll_item, employee)
      end

      payroll_item.additional_withholding = employee.additional_withholding.to_f
      payroll_item.clear_wage_rate_hours!
      payroll_item.employment_type = employee.employment_type
      payroll_item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
    end

    def reset_stale_intake_item_fields!(payroll_item, employee)
      salary_override = salary_override_to_preserve(payroll_item, employee)

      payroll_item.additional_withholding = employee.additional_withholding.to_f
      payroll_item.additional_withholding_override = nil
      payroll_item.withholding_tax_adjustment = nil
      payroll_item.withholding_tax_override = nil
      payroll_item.salary_override = salary_override
      payroll_item.holiday_hours = 0
      payroll_item.pto_hours = 0
      payroll_item.bonus = 0
      payroll_item.non_taxable_pay = 0
      payroll_item.loan_payment = 0
      payroll_item.insurance_payment = 0
      payroll_item.custom_earnings = []
      payroll_item.custom_deductions = []
      payroll_item.payroll_adjustments = [] unless payroll_item.payroll_adjustments_overridden?
      payroll_item.payroll_item_field_entries.destroy_all
      payroll_item.custom_columns_data = reset_intake_custom_columns(payroll_item.custom_columns_data)
    end

    def salary_override_to_preserve(payroll_item, employee)
      return payroll_item.salary_override if employee.variable_salary?

      nil
    end

    def reset_intake_custom_columns(custom_columns_data)
      data = custom_columns_data.is_a?(Hash) ? custom_columns_data.deep_dup : {}
      data.except(
        "wage_rate_hours",
        :wage_rate_hours
      )
    end
  end
end
