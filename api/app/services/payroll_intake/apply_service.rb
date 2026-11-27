# frozen_string_literal: true

require "bigdecimal"
require "set"

module PayrollIntake
  # Unified apply orchestrator for all payroll intake adapters:
  # - Cornerstone universal workbook (`cornerstone_workbook`)
  # - Spike Coffee Roasters email (`spike_email`)
  # - Reviewed-hours packages such as MoSa Revel (`mosa_revel`) via
  #   `#apply_reviewed_import!`
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
      PayrollIntake::SourcePackageVerifier.new(session: session).verify!

      results = { applied: [], skipped: [], errors: [] }

      ActiveRecord::Base.transaction do
        Company.lock.find(company.id)
        pay_period.with_lock do
          raise ArgumentError, "Cannot apply to a non-editable pay period" unless pay_period.can_edit?
          if pay_period.pending_portal_submission? ||
            PayrollImportRecord.where(payroll_intake_session_id: session.id).joins(:submission_imports).exists? ||
            session.documents.where.not(payroll_submission_document_id: nil).exists?
            raise ArgumentError, "Review portal sources through the MoSa import review before applying"
          end

          excluded_employee_ids = pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set

          session.with_lock(requires_new: true) do
            raise ArgumentError, "Only previewed payroll intake sessions can be applied" unless session.applyable?
            validate_workweek_snapshot!

            disposition_plan = PayrollIntake::DispositionPlan.new(
              session: session,
              row_overrides: row_overrides,
              actor: actor
            ).validate!
            decisions = disposition_plan.decisions
            duplicate_employee_ids = duplicate_employee_ids_for(decisions, excluded_employee_ids)

            decisions.each do |decision|
              row = decision.row
              override = decision.override
              unless decision.included?
                disposition_plan.apply!(decision, status: "skipped")
                results[:skipped] << {
                  row_id: row.id,
                  source_employee_name: row.source_employee_name,
                  reason: decision.disposition,
                  target_pay_period_id: decision.target_pay_period&.id
                }
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
                results[:errors] << {
                  row_id: row.id,
                  employee_id: employee.id,
                  source_employee_name: row.source_employee_name,
                  error: "This employee is excluded from the pay period. Choose Excluded and record why."
                }
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
              validate_contractor_fields!(employee, values)

              payroll_item = pay_period.payroll_items.lock.find_or_initialize_by(employee_id: employee.id)
              overwrite_error = overwrite_error_for(payroll_item)
              if overwrite_error
                results[:errors] << { row_id: row.id, employee_id: employee.id, source_employee_name: row.source_employee_name, error: overwrite_error }
                next
              end

              if payroll_item.variable_salary_missing?
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
              disposition_plan.apply!(
                decision,
                status: "applied",
                employee: employee,
                payroll_item: payroll_item,
                staff_overrides: override
              )

              results[:applied] << {
                row_id: row.id,
                employee_id: employee.id,
                employee_name: employee.full_name,
                regular_hours: payroll_item.hours_worked.to_f,
                overtime_hours: payroll_item.overtime_hours.to_f,
                pto_hours: payroll_item.pto_hours.to_f,
                holiday_hours: payroll_item.holiday_hours.to_f,
                reported_tips: payroll_item.reported_tips.to_f,
                tips_paid_out: payroll_item.tips_paid_out.to_f,
                bonus: payroll_item.bonus.to_f,
                loan_deduction: payroll_item.loan_deduction.to_f
              }
            rescue ActiveRecord::RecordInvalid, ArgumentError => e
              results[:errors] << { row_id: row.id, source_employee_name: row.source_employee_name, error: e.message }
            end

            raise ActiveRecord::Rollback if results[:errors].any?

            if results[:applied].any?
              update_pay_period_after_apply!
            elsif pay_period.intake_stale_session_id == session.id
              pay_period.clear_intake_stale!
            end
            finalize_session_after_apply!
          end
        end
      end

      results
    end

    # Unified reviewed-package apply path (used by PayrollImportsController#apply
    # for MoSa Revel and any reviewed-hours descriptor adapter). The caller holds
    # the outer Company + PayPeriod lock via `with_import_lock`.
    def apply_reviewed_import!(import_record:, matched_data:, disposition_plan:, tips_paid_out_from_tips:,
                               selection: nil, client_changes: nil, source_waivers: [], hand_edited_hours: [],
                               unpaid_owners: {})
      raise ArgumentError, "Cannot apply to a non-editable pay period" unless pay_period.can_edit?
      raise ArgumentError, "Only previewed payroll intake sessions can be applied" unless session.applyable?

      results = { success: [], skipped: [], errors: [] }
      applied = false

      ActiveRecord::Base.transaction(requires_new: true) do
        # This selection resolves the pending-source gate only inside the
        # same transaction as successful calculation/apply. Any failure
        # rolls it back along with every payroll row and status event.
        selection.period.save! if selection && selection.period.changed?
        selection&.save! if selection&.new_record?
        selection&.update!(applied_at: Time.current)
        client_changes&.apply_period_decisions!(actor: actor)

        if universal_workbook?
          session.with_lock(requires_new: true) do
            raise ArgumentError, "Only previewed payroll intake sessions can be applied" unless session.applyable?
            validate_workweek_snapshot!
            apply_universal_workbook_reviewed_decisions!(
              matched_data: matched_data,
              disposition_plan: disposition_plan,
              unpaid_owners: unpaid_owners,
              tips_paid_out_from_tips: tips_paid_out_from_tips,
              results: results
            )
            raise ActiveRecord::Rollback if results[:errors].any?

            import_record.update!(
              status: "applied",
              validation_errors: [],
              import_origin: PayrollIntake::ImportOrigin.build(
                session: session,
                portal_submission: selection&.payroll_submission,
                replaced_hand_edited_hours: hand_edited_hours.any?
              ),
              raw_data: import_record.raw_data.to_h.merge(
                "client_change_decisions" => client_changes&.review_decisions || [],
                "source_waivers" => source_waivers,
                "replaced_hand_edited_hours" => hand_edited_hours
              )
            )

            if results[:success].any?
              update_pay_period_after_apply!
            elsif pay_period.intake_stale_session_id == session.id
              pay_period.clear_intake_stale!
            end
            finalize_session_after_apply!

            if selection
              record_portal_selection_applied!(
                selection: selection,
                client_changes: client_changes,
                import_record: import_record
              )
            end

            applied = true
          end
        else
          if matched_data.any?
            service = PayrollImport::ImportService.new(pay_period, actor: actor)
            results = service.apply!(
              matched: matched_data,
              force_overwrite: force_overwrite,
              tips_paid_out_from_tips: tips_paid_out_from_tips
            )
          end
          raise ActiveRecord::Rollback if results[:errors].any?

          import_record.update!(
            status: "applied",
            validation_errors: [],
            import_origin: PayrollIntake::ImportOrigin.build(
              session: session,
              portal_submission: selection&.payroll_submission,
              replaced_hand_edited_hours: hand_edited_hours.any?
            ),
            raw_data: import_record.raw_data.to_h.merge(
              "client_change_decisions" => client_changes&.review_decisions || [],
              "source_waivers" => source_waivers,
              "replaced_hand_edited_hours" => hand_edited_hours
            )
          )

          disposition_plan.decisions.each do |decision|
            if decision.included? && unpaid_owners.key?(decision.row.employee_id)
              decision.disposition = "excluded"
              decision.reason = unpaid_owners[decision.row.employee_id]
            end
            if decision.included?
              payroll_item = pay_period.payroll_items.find_by!(employee_id: decision.row.employee_id)
              disposition_plan.apply!(
                decision,
                status: "applied",
                employee: decision.row.employee,
                payroll_item: payroll_item
              )
            else
              disposition_plan.apply!(decision, status: "skipped")
              results[:skipped] << {
                employee_id: decision.row.employee_id,
                name: decision.row.source_employee_name,
                reason: decision.reason
              }
            end
          end

          finalize_session_after_apply!
          pay_period.clear_intake_stale! if pay_period.intake_stale_session_id == session.id

          if selection
            record_portal_selection_applied!(
              selection: selection,
              client_changes: client_changes,
              import_record: import_record
            )
          end

          applied = true
        end
      end

      { applied: applied, results: results }
    end

    private

    attr_reader :session, :pay_period, :company, :row_overrides, :actor, :force_overwrite, :acknowledge_warnings

    def descriptor
      @descriptor ||= PayrollIntake::Registry.find(session.source_type)
    end

    def universal_workbook?
      session.source_type == "cornerstone_workbook"
    end

    def resolved_pay_frequency
      @resolved_pay_frequency ||= PayrollIntake::WorkweekEvidence.pay_frequency_for(
        pay_period: pay_period,
        company: company
      )
    end

    def validate_workweek_snapshot!
      PayrollIntake::WorkweekEvidence.new(
        pay_period: pay_period,
        allow_misaligned: effective_settings.allow_misaligned_workweek?,
        overtime_mode: effective_settings.overtime_mode,
        workweek_alignment: effective_settings.workweek_alignment
      ).validate_snapshot!(
        session.evidence_snapshot.to_h["workweek"]
      )
    end

    def finalize_session_after_apply!
      session.mark_reviewed!(actor: actor) if session.status == "previewed"
      session.mark_applied!(actor: actor)
    end

    def record_portal_selection_applied!(selection:, client_changes:, import_record:)
      period = selection.period
      # Keep Imported tied to the actual selected revision; choosing
      # an old source does not label the newer files as imported.
      review_notes = client_changes.review_decisions.select { |row| %w[decline no_pay stale_none].include?(row[:decision]) }
        .map do |row|
          next row[:reason] if row[:decision] == "stale_none"

          "#{row[:employee_name] || 'Missing employee'}: #{row[:decision] == 'no_pay' ? 'No pay this period' : "Don't apply"} — #{row[:reason]}"
        end
      period.transition!(
        "import",
        actor: actor,
        submission: selection.payroll_submission,
        note: ([ "Imported revision #{selection.payroll_submission.revision} into payroll review." ] + review_notes).join(" ")
      )
      PayrollSubmissions::Audit.record!(
        actor: actor,
        period: period,
        action: "payroll_submission_periods#import",
        metadata: {
          pay_period_id: pay_period.id,
          submission_id: selection.payroll_submission_id,
          current_submission_id: selection.current_submission_id,
          superseded_reason: selection.superseded_reason,
          source_route: selection.source_route,
          staff_workbook_document_id: selection.staff_workbook_document_id,
          client_change_decisions: client_changes.review_decisions,
          import_id: import_record.id,
          source_package_id: session.id
        }
      )
      PortalNotifications.payroll_period!(
        "payroll_submission_imported",
        period: period,
        actor: actor,
        dedupe: "import:#{import_record.id}",
        metadata: {
          submission_id: selection.payroll_submission_id,
          revision: selection.payroll_submission.revision
        }
      )
    end

    def acknowledged?(override)
      acknowledge_warnings || ActiveModel::Type::Boolean.new.cast(override[:acknowledge_warnings])
    end

    def employee_for(row, override)
      employee_id = if descriptor&.employee_match == "employee_id"
        row.employee_id
      else
        override[:employee_id].presence || row.employee_id
      end
      return nil if employee_id.blank?

      Employee.active.find_by(id: employee_id, company_id: company.id)
    end

    def duplicate_employee_ids_for(decisions, excluded_employee_ids)
      mapped_employee_ids = decisions.filter_map do |decision|
        next unless decision.included?

        employee = employee_for(decision.row, decision.override)
        next if employee.blank? || excluded_employee_ids.include?(employee.id)

        employee.id
      end

      mapped_employee_ids.tally.select { |_employee_id, count| count > 1 }.keys.to_set
    end

    def values_for(row, override)
      payload = row.source_payload.to_h
      raw_bonus = if override.key?(:bonus)
        override[:bonus]
      elsif payload.key?("bonus")
        payload["bonus"]
      end

      {
        regular_hours: decimal_override(override, :regular_hours, row.regular_hours),
        overtime_hours: decimal_override(override, :overtime_hours, row.overtime_hours),
        week1_hours: decimal_override(override, :week1_hours, row.week1_hours),
        week2_hours: decimal_override(override, :week2_hours, row.week2_hours),
        pto_hours: decimal_override(override, :pto_hours, payload["pto_hours"].presence || 0),
        holiday_hours: decimal_override(override, :holiday_hours, payload["holiday_hours"].presence || 0),
        week1_tips: decimal_override(override, :week1_tips, row.week1_tips),
        week2_tips: decimal_override(override, :week2_tips, row.week2_tips),
        reported_tips: decimal_override(override, :reported_tips, row.reported_tips),
        tips_paid_out: decimal_override(override, :tips_paid_out, row.tips_paid_out),
        bonus: raw_bonus.nil? || raw_bonus.to_s.strip.empty? ? nil : strict_nonnegative_decimal(raw_bonus, :bonus),
        payroll_components: Array(payload["payroll_components"]),
        loan_deduction: decimal_override(override, :loan_deduction, row.loan_deduction)
      }
    end

    def effective_settings
      @effective_settings ||= PayrollIntake::EffectiveSettings.for(
        company: company,
        pay_period: pay_period,
        source_type: session.source_type
      )
    end

    def resolved_overtime_mode
      session.evidence_snapshot.to_h.dig("intake_settings", "overtime_mode").presence ||
        session.evidence_snapshot.to_h["overtime_mode"].presence ||
        effective_settings.overtime_mode
    end

    def validated_values_for(row, override)
      values = values_for(row, override)
      mode = resolved_overtime_mode

      if mode == "source_reports"
        combined = values.fetch(:regular_hours) + values.fetch(:overtime_hours)
        weekly_combined = values.fetch(:week1_hours) + values.fetch(:week2_hours)
        if weekly_combined.positive? && !reconciles?(weekly_combined, combined)
          raise ArgumentError,
                "Week 1 + Week 2 hours (#{format('%.2f', weekly_combined)}) must reconcile with " \
                "Regular + Overtime hours (#{format('%.2f', combined)}) when overtime mode is source_reports"
        end
        if row.total_hours.to_d.positive? && !override.key?(:regular_hours) && !override.key?(:overtime_hours) && !reconciles?(combined, row.total_hours)
          raise ArgumentError, "Regular + overtime hours must equal the extracted row total of #{format('%.2f', row.total_hours)} hours"
        end
        return values
      end

      week1 = values.fetch(:week1_hours)
      week2 = values.fetch(:week2_hours)
      has_weekly = week1.positive? || week2.positive?

      if mode == "total_as_regular_warn_over_80" && !has_weekly
        combined = values.fetch(:regular_hours) + values.fetch(:overtime_hours)
        unless reconciles?(combined, row.total_hours)
          raise ArgumentError, "Regular + overtime hours must equal the extracted row total of #{format('%.2f', row.total_hours)} hours"
        end
        if values.fetch(:overtime_hours) < BigDecimal(row.overtime_hours.to_s)
          raise ArgumentError,
                "Overtime hours cannot be reduced below #{format('%.2f', row.overtime_hours)} hours in warn-over-80 mode"
        end
        return values
      end

      daily_entries = Array(row.source_payload.to_h["daily_hours"] || row.source_payload.to_h["days"]).select { |entry| entry.is_a?(Hash) }
      if mode == "daily_records" && daily_entries.any?
        regular_hours, overtime_hours, daily_errors = PayrollIntake::Adapters::SpikeEmail.split_for_daily_records(
          daily_entries,
          pay_period: pay_period
        )
        raise ArgumentError, daily_errors.first.fetch(:message) if daily_errors.any?

        unless reconciles?(regular_hours + overtime_hours, row.total_hours)
          raise ArgumentError, "Daily hours must equal the extracted row total of #{format('%.2f', row.total_hours)} hours"
        end
        unless reconciles?(values.fetch(:regular_hours), regular_hours) && reconciles?(values.fetch(:overtime_hours), overtime_hours)
          raise ArgumentError,
                "Regular/overtime overrides must match Payroll's legal daily-workweek calculation " \
                "(#{format('%.2f', regular_hours)} regular / #{format('%.2f', overtime_hours)} overtime)"
        end
        return values.merge(regular_hours: regular_hours, overtime_hours: overtime_hours)
      end

      if resolved_pay_frequency == "weekly"
        if week2.positive?
          raise ArgumentError, "Week 2 hours cannot be nonzero on a weekly pay period"
        end
        if week1 > 168
          raise ArgumentError, "Week 1 hours cannot exceed 168 hours"
        end
        unless reconciles?(week1, row.total_hours)
          raise ArgumentError, "Week 1 hours must equal the extracted row total of #{format('%.2f', row.total_hours)} hours"
        end
        regular_hours, overtime_hours = PayrollIntake::Adapters::CornerstoneWorkbook.split_for_weekly_hours(week1, 0.to_d)
      else
        weekly_total = week1 + week2
        if week1 > 168 || week2 > 168
          raise ArgumentError, "Week 1 and Week 2 hours cannot exceed 168 hours"
        end
        unless reconciles?(weekly_total, row.total_hours)
          raise ArgumentError, "Week 1 + Week 2 hours must equal the extracted row total of #{format('%.2f', row.total_hours)} hours"
        end
        regular_hours, overtime_hours = PayrollIntake::Adapters::CornerstoneWorkbook.split_for_weekly_hours(week1, week2)
      end
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
      if resolved_pay_frequency == "weekly"
        return false unless override.key?(:week1_hours)

        week1 = decimal_override(override, :week1_hours, row.week1_hours)
        week2 = decimal_override(override, :week2_hours, row.week2_hours)
        return week2.zero? && reconciles?(week1, row.total_hours)
      end

      return false unless override.key?(:week1_hours) && override.key?(:week2_hours)

      week1 = decimal_override(override, :week1_hours, row.week1_hours)
      week2 = decimal_override(override, :week2_hours, row.week2_hours)
      reconciles?(week1 + week2, row.total_hours)
    end

    def decimal_override(override, key, fallback)
      value = override.key?(key) ? override[key] : fallback
      strict_nonnegative_decimal(value, key)
    end

    def strict_nonnegative_decimal(value, key)
      raise ArgumentError, "#{key.to_s.humanize} must be a finite non-negative number" if value == true || value == false

      number = BigDecimal(value.to_s, exception: false)
      raise ArgumentError, "#{key.to_s.humanize} must be a finite non-negative number" unless number&.finite? && !number.negative?

      number.round(2)
    end

    def reconciles?(left, right)
      (BigDecimal(left.to_s) - BigDecimal(right.to_s)).abs <= BigDecimal("0.01")
    end

    def overwrite_error_for(payroll_item)
      return nil unless payroll_item.persisted?
      return nil if force_overwrite
      return nil if payroll_item.imported_by?(session.source_type)

      "Payroll item already exists from another source or manual entry. Use force overwrite only after review."
    end

    def update_pay_period_after_apply!
      pay_period.update!(
        status: "calculated",
        calculated_at: Time.current,
        calculated_by_id: actor&.id,
        approved_at: nil,
        approved_by_id: nil,
        intake_stale_at: nil,
        intake_stale_reason: nil,
        intake_stale_session: nil
      )
      PayrollReview::RevisionService.new(pay_period: pay_period, actor: actor).issue!
    end

    def apply_values!(payroll_item, employee, values, matched_row: nil)
      prepare_payroll_item_for_intake!(payroll_item, employee)

      payroll_item.hours_worked = values[:regular_hours]
      payroll_item.overtime_hours = values[:overtime_hours]
      payroll_item.pto_hours = values[:pto_hours]
      payroll_item.holiday_hours = values[:holiday_hours]
      payroll_item.reported_tips = values[:reported_tips]
      payroll_item.tips_paid_out = values[:tips_paid_out]
      payroll_item.tips = 0.to_d if payroll_item.respond_to?(:tips=)
      persist_tip_components!(payroll_item, values)
      payroll_item.loan_deduction = values[:loan_deduction]
      PayrollBonusInput.import!(payroll_item, values[:bonus], source: "import") unless values[:bonus].nil?
      payroll_item.import_source = session.source_type
      payroll_item.import_origin = "intake"
      record_reviewed_hours_baseline!(payroll_item, values) if payroll_item.tracks_reviewed_hours?
      payroll_item.sync_default_payroll_adjustments!(employee)
      if universal_workbook? || values[:payroll_components].any?
        PayrollIntake::ComponentApplier.new(pay_period: pay_period).apply!(payroll_item, values[:payroll_components])
      end
      apply_reviewed_client_changes!(payroll_item, employee, matched_row) if matched_row.present?
      payroll_item.calculate!
    end

    def record_reviewed_hours_baseline!(payroll_item, values)
      data = payroll_item.custom_columns_data.is_a?(Hash) ? payroll_item.custom_columns_data.deep_dup : {}
      recorded_hours = {
        "regular_hours" => BigDecimal(values[:regular_hours].to_s).to_s("F"),
        "overtime_hours" => BigDecimal(values[:overtime_hours].to_s).to_s("F")
      }
      data["imported_hours"] = recorded_hours
      data["mosa_imported_hours"] = recorded_hours
      payroll_item.custom_columns_data = data
    end

    def persist_tip_components!(payroll_item, values)
      components = [
        { "label" => "Tips 1", "amount" => values[:week1_tips].to_d.round(2).to_f },
        { "label" => "Tips 2", "amount" => values[:week2_tips].to_d.round(2).to_f }
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
      payroll_item.employment_type = employee.payroll_compensation_on(@pay_period.end_date).employment_type
      payroll_item.pay_rate = employee.default_payroll_rate_on(pay_period.end_date)
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
      unless universal_workbook? && PayrollBonusInput.manual?(payroll_item)
        payroll_item.bonus = 0
        # A blank replacement clears source-controlled bonus provenance so
        # stale "import" metadata never remains on a zeroed bonus. Manual
        # bonuses preserve both their amount and bonus_source = "manual".
        payroll_item.bonus_source = nil
        payroll_item.imported_bonus = nil
      end
      payroll_item.non_taxable_pay = 0
      payroll_item.loan_payment = 0
      payroll_item.insurance_payment = 0
      payroll_item.custom_earnings = []
      payroll_item.custom_deductions = []
      payroll_item.payroll_adjustments = [] unless payroll_item.payroll_adjustments_overridden?
      if universal_workbook?
        import_entries = payroll_item.payroll_item_field_entries.select { |entry| entry.source == "import" }
        payroll_item.payroll_item_field_entries.destroy(*import_entries)
      else
        payroll_item.payroll_item_field_entries.destroy_all
      end
      payroll_item.custom_columns_data = reset_intake_custom_columns(payroll_item.custom_columns_data)
    end

    def salary_override_to_preserve(payroll_item, employee)
      return payroll_item.salary_override if employee.payroll_compensation_on(@pay_period.end_date).variable_salary?

      nil
    end

    def validate_contractor_fields!(employee, values)
      compensation = employee.payroll_compensation_on(pay_period.end_date)
      return unless compensation.employment_type == "contractor"

      errors = []
      if values.fetch(:pto_hours).positive?
        errors << "1099 contractors cannot receive PTO hours (#{format('%.2f', values[:pto_hours])}). Clear PTO Hours before applying."
      end
      if values.fetch(:holiday_hours).positive?
        errors << "1099 contractors cannot receive holiday hours (#{format('%.2f', values[:holiday_hours])}). Clear Holiday Hours before applying."
      end
      if values.fetch(:reported_tips).positive? || values.fetch(:tips_paid_out).positive?
        errors << "1099 contractors cannot receive employee tips or tip offsets. Clear Tips before applying."
      end
      if compensation.contractor_pay_type != "hourly" &&
        (values.fetch(:regular_hours).positive? || values.fetch(:overtime_hours).positive? ||
          values.fetch(:week1_hours).positive? || values.fetch(:week2_hours).positive?)
        errors << "Flat-fee 1099 contractors cannot receive hourly wages via hours columns. Clear Hours before applying."
      end
      raise ArgumentError, errors.join(" ") if errors.any?
    end

    def apply_universal_workbook_reviewed_decisions!(matched_data:, disposition_plan:, unpaid_owners:, tips_paid_out_from_tips:, results:)
      excluded_employee_ids = pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set
      decisions = disposition_plan.decisions
      duplicate_employee_ids = duplicate_employee_ids_for(decisions, excluded_employee_ids)
      matched_rows = Array(matched_data).map { |entry| entry.to_h.deep_symbolize_keys }
      matched_by_employee_id = matched_rows.index_by { |entry| entry[:employee_id].to_i }
      handled_employee_ids = Set.new

      decisions.each do |decision|
        row = decision.row
        override = decision.override
        if decision.included? && unpaid_owners.key?(row.employee_id)
          decision.disposition = "excluded"
          decision.reason = unpaid_owners[row.employee_id]
        end

        unless decision.included?
          disposition_plan.apply!(decision, status: "skipped")
          results[:skipped] << {
            employee_id: row.employee_id,
            name: row.source_employee_name,
            reason: decision.reason || decision.disposition
          }
          next
        end

        if row.warnings_payload.any? && !acknowledged?(override)
          results[:errors] << { employee_id: row.employee_id, name: row.source_employee_name, error: "Review or acknowledge row warnings before applying." }
          next
        end

        employee = employee_for(row, override)
        unless employee
          results[:errors] << { employee_id: row.employee_id, name: row.source_employee_name, error: "Employee mapping required" }
          next
        end

        if excluded_employee_ids.include?(employee.id)
          results[:errors] << { employee_id: employee.id, name: row.source_employee_name, error: "This employee is excluded from the pay period. Choose Excluded and record why." }
          next
        end

        if duplicate_employee_ids.include?(employee.id)
          results[:errors] << { employee_id: employee.id, name: row.source_employee_name, error: "Multiple included intake rows map to #{employee.full_name}. Exclude duplicates before applying." }
          next
        end

        unresolved_errors = unresolved_validation_errors(row, override, employee)
        if unresolved_errors.any?
          results[:errors] << { employee_id: employee.id, name: row.source_employee_name, error: unresolved_errors.join(" ") }
          next
        end

        matched_row = matched_by_employee_id[employee.id]
        handled_employee_ids << employee.id

        values = validated_values_for(row, override)
        if values[:tips_paid_out].positive? && values[:reported_tips] < values[:tips_paid_out]
          values[:reported_tips] = values[:tips_paid_out]
        end
        validate_contractor_fields!(employee, values)

        payroll_item = pay_period.payroll_items.lock.find_or_initialize_by(employee_id: employee.id)
        overwrite_error = overwrite_error_for(payroll_item)
        if overwrite_error
          results[:errors] << { employee_id: employee.id, name: row.source_employee_name, error: overwrite_error }
          next
        end

        if payroll_item.variable_salary_missing? && matched_row&.dig(:period_pay).to_d <= 0
          results[:errors] << { employee_id: employee.id, name: row.source_employee_name, error: "Enter this employee's variable salary amount before applying payroll intake." }
          next
        end

        apply_values!(payroll_item, employee, values, matched_row: matched_row)
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
        disposition_plan.apply!(
          decision,
          status: "applied",
          employee: employee,
          payroll_item: payroll_item,
          staff_overrides: override
        )

        results[:success] << {
          employee_id: employee.id,
          employee_name: employee.full_name,
          regular_hours: payroll_item.hours_worked.to_f,
          overtime_hours: payroll_item.overtime_hours.to_f,
          pto_hours: payroll_item.pto_hours.to_f,
          holiday_hours: payroll_item.holiday_hours.to_f,
          reported_tips: payroll_item.reported_tips.to_f,
          tips_paid_out: payroll_item.tips_paid_out.to_f,
          bonus: payroll_item.bonus.to_f,
          loan_deduction: payroll_item.loan_deduction.to_f
        }
      rescue ActiveRecord::RecordInvalid, ArgumentError => e
        results[:errors] << { employee_id: row.employee_id, name: row.source_employee_name, error: e.message }
      end

      return if results[:errors].any?

      client_only_rows = matched_rows.reject { |entry| handled_employee_ids.include?(entry[:employee_id].to_i) }
      return if client_only_rows.empty?

      extra_results = PayrollImport::ImportService.new(pay_period, actor: actor).apply!(
        matched: client_only_rows,
        force_overwrite: force_overwrite,
        tips_paid_out_from_tips: tips_paid_out_from_tips
      )
      results[:success].concat(Array(extra_results[:success]))
      results[:skipped].concat(Array(extra_results[:skipped]))
      results[:errors].concat(Array(extra_results[:errors]))
    end

    def apply_reviewed_client_changes!(payroll_item, employee, matched_row)
      apply_client_period_pay!(payroll_item, employee, matched_row) if matched_row[:period_pay].present?
      apply_client_extra_hours!(payroll_item, employee, matched_row) if matched_row[:client_extra_hours].present?
      if matched_row[:client_change_evidence].present?
        data = payroll_item.custom_columns_data.is_a?(Hash) ? payroll_item.custom_columns_data.deep_dup : {}
        data["client_change_evidence"] = matched_row[:client_change_evidence].deep_stringify_keys
        payroll_item.custom_columns_data = data
      end
    end

    def apply_client_period_pay!(payroll_item, employee, matched_row)
      amount = BigDecimal(matched_row[:period_pay].to_s, exception: false)&.round(2) || 0.to_d
      return if amount.zero?

      raise ArgumentError, "Pay this employee must be a positive amount." unless amount.positive?
      raise ArgumentError, "Pay this employee is only allowed for variable-pay salary employees." unless employee.payroll_compensation_on(pay_period.end_date).variable_salary?

      evidence = matched_row[:period_pay_evidence].to_h.deep_symbolize_keys
      raise ArgumentError, "Pay this employee must confirm THIS EMPLOYEE ONLY." unless evidence[:scope] == "THIS EMPLOYEE ONLY"
      raise ArgumentError, "Pay this employee requires a source or reason." if evidence[:source].to_s.strip.blank?
      unless Date.iso8601(evidence[:effective_pay_date].to_s) == pay_period.pay_date
        raise ArgumentError, "Pay this employee must use this payroll's pay date."
      end

      payroll_item.salary_override = amount
      data = payroll_item.custom_columns_data.is_a?(Hash) ? payroll_item.custom_columns_data.deep_dup : {}
      data["period_pay_evidence"] = evidence.deep_stringify_keys.merge(
        "amount" => amount.to_s("F"),
        "employee_id" => employee.id,
        "employee_name" => employee.full_name,
        "source_type" => evidence[:source_type] == "client_submission" ? "client_submission" : "mosa_change_workbook"
      )
      payroll_item.custom_columns_data = data
    rescue Date::Error
      raise ArgumentError, "Pay this employee must use this payroll's pay date."
    end

    def apply_client_extra_hours!(payroll_item, employee, matched_row)
      input = matched_row.fetch(:client_extra_hours).to_h.deep_symbolize_keys
      period_rates = employee.wage_rates_on(pay_period.end_date)
      rate = period_rates.find { |candidate| candidate.id.to_s == input[:employee_wage_rate_id].to_s }
      unless rate && rate.rate == BigDecimal(input[:rate].to_s)
        raise ArgumentError, "Saved job and rate changed for #{employee.full_name}. Review the client change again."
      end

      extra_hours = BigDecimal(input[:hours].to_s).round(2)
      raise ArgumentError, "Extra hours must be greater than zero for #{employee.full_name}." unless extra_hours.positive?

      baseline_hours = payroll_item.hours_worked.to_d.to_s("F")
      baseline_allocations = payroll_item.wage_rate_hours.deep_dup
      allocations = payroll_item.wage_rate_hours.deep_dup

      if allocations.empty? && [ payroll_item.hours_worked, payroll_item.overtime_hours, payroll_item.holiday_hours, payroll_item.pto_hours ].any? { |hours| hours.to_d.positive? }
        base = if matched_row[:selected_wage_rate_id].present?
          period_rates.find { |candidate| candidate.id.to_s == matched_row[:selected_wage_rate_id].to_s }
        else
          primary = employee.primary_wage_rate_on(pay_period.end_date)
          primary if primary && primary.rate == payroll_item.pay_rate && period_rates.map(&:rate).uniq.one?
        end
        unless base
          raise ArgumentError, "Choose a saved job for the existing hours for #{employee.full_name}."
        end

        allocations << {
          "employee_wage_rate_id" => base.id,
          "label" => base.label,
          "rate" => base.rate.to_f,
          "regular_hours" => payroll_item.hours_worked.to_f,
          "overtime_hours" => payroll_item.overtime_hours.to_f,
          "holiday_hours" => payroll_item.holiday_hours.to_f,
          "pto_hours" => payroll_item.pto_hours.to_f,
          "active" => true,
          "is_primary" => base.is_primary
        }
      end

      entry = allocations.find { |allocation| allocation["employee_wage_rate_id"].to_s == rate.id.to_s && allocation["rate"].to_d == rate.rate }
      unless entry
        entry = {
          "employee_wage_rate_id" => rate.id,
          "label" => rate.label,
          "rate" => rate.rate.to_f,
          "regular_hours" => 0,
          "overtime_hours" => 0,
          "holiday_hours" => 0,
          "pto_hours" => 0,
          "is_primary" => rate.is_primary,
          "active" => true
        }
        allocations << entry
      end

      entry["regular_hours"] = (entry["regular_hours"].to_d + extra_hours).round(2).to_f
      payroll_item.hours_worked = (payroll_item.hours_worked.to_d + extra_hours).round(2)
      payroll_item.wage_rate_hours = allocations

      if matched_row[:client_change_evidence].present?
        matched_row[:client_change_evidence] = matched_row[:client_change_evidence].merge(
          baseline_regular_hours: baseline_hours,
          baseline_allocations: baseline_allocations,
          applied_regular_hours: payroll_item.hours_worked.to_d.to_s("F"),
          applied_allocations: payroll_item.wage_rate_hours,
          applied_hours: %w[hours_worked overtime_hours holiday_hours pto_hours].to_h { |field| [ field, payroll_item.public_send(field).to_d.to_s("F") ] }
        )
      end
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
