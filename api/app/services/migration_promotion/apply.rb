# frozen_string_literal: true

module MigrationPromotion
  class Apply
    ACKNOWLEDGEMENT = "APPLY REHEARSAL TO LIVE CLIENT"
    PAYROLL_ITEM_CLEAR_COLUMNS = {
      "check_number" => nil,
      "check_date" => nil,
      "check_printed_at" => nil,
      "check_print_count" => 0,
      "reprint_of_check_number" => nil,
      "replaced_check_number" => nil,
      "voided" => false,
      "voided_at" => nil,
      "voided_by_user_id" => nil,
      "void_reason" => nil,
      "correction_for_payroll_item_id" => nil,
      "correction_reason" => nil
    }.freeze

    def initialize(rehearsal:, actor:, acknowledgement:)
      @rehearsal = rehearsal
      @target_company = rehearsal.migration_source_company
      @actor = actor
      @acknowledgement = acknowledgement
    end

    def call
      authorize!
      raise ArgumentError, "Confirm application of the rehearsal to the live client" unless acknowledgement == ACKNOWLEDGEMENT

      promoted_periods = []
      transaction_options = ApplicationRecord.connection.transaction_open? ? {} : { isolation: :repeatable_read }
      ApplicationRecord.transaction(**transaction_options) do
        lock_companies!
        preview = Preview.new(rehearsal: rehearsal)
        payload = preview.call
        raise ArgumentError, payload.fetch(:blockers).join("; ") unless payload.fetch(:ready_to_apply)

        backup = preview.promotion_backup
        mapping = preview.employee_mapping
        target_company.pay_periods.draft.find_each(&:destroy!)
        maps = SetupSynchronizer.new(
          rehearsal: rehearsal,
          target_company: target_company,
          actor: actor,
          mapping: mapping
        ).call
        promoted_periods = preview.source_periods.map { |source| copy_period!(source, maps) }
        apply_financial_effects!(promoted_periods)
        verify!(preview.source_periods, promoted_periods)

        completed_at = Time.current
        rehearsal.update!(
          test_workspace_sealed_at: completed_at,
          test_workspace_manifest: rehearsal.test_workspace_manifest.merge(
            "promotion_status" => "completed",
            "promotion_backup_company_id" => backup.id,
            "promoted_target_company_id" => target_company.id,
            "promoted_source_pay_period_ids" => preview.source_periods.map(&:id),
            "promoted_pay_period_ids" => promoted_periods.map(&:id),
            "promoted_at" => completed_at.iso8601
          )
        )
        target_company.touch
        audit_completed!(backup, preview.source_periods, promoted_periods)
      end

      promoted_periods
    end

    private

    attr_reader :rehearsal, :target_company, :actor, :acknowledgement

    def authorize!
      allowed = actor&.organization_admin? && actor.can_access_company?(rehearsal.id) &&
        actor.can_access_company?(target_company&.id) && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator with access to both clients is required" unless allowed
    end

    def lock_companies!
      Company.lock.where(id: [ rehearsal.id, target_company.id ]).order(:id).load
      rehearsal.reload
      target_company.reload
    end

    def copy_period!(source, maps)
      attributes = source.attributes.except(
        "id", "created_at", "updated_at", "company_id", "company_pay_schedule_id", "company_workweek_id",
        "corrects_pay_period_id", "source_pay_period_id", "superseded_by_id", "intake_stale_session_id",
        "test_workspace_source_pay_period_id", "test_workspace_role", "promotion_source_pay_period_id"
      )
      target = PayPeriod.create!(attributes.merge(
        company: target_company,
        company_pay_schedule: source.company_pay_schedule_id && maps.fetch(:pay_schedules).fetch(source.company_pay_schedule_id),
        company_workweek: source.company_workweek_id && maps.fetch(:workweeks).fetch(source.company_workweek_id),
        status: "committed",
        parallel_run: false,
        run_purpose_source: "production_migration",
        cycle: "regular",
        promotion_source_pay_period: source,
        created_by_id: actor.id,
        committed_by_id: actor.id,
        committed_at: Time.current,
        correction_status: nil,
        corrects_pay_period_id: nil,
        source_pay_period_id: nil,
        superseded_by_id: nil,
        # These periods already occurred in the legacy system. Keep them out of
        # the live tax-sync queue while preserving their payroll/YTD records.
        tax_sync_status: nil,
        tax_sync_attempts: 0,
        tax_sync_last_error: nil,
        tax_synced_at: nil,
        tax_sync_idempotency_key: nil,
        intake_stale_at: nil,
        intake_stale_reason: nil,
        intake_stale_session_id: nil
      ))

      source.payroll_items.not_voided.order(:id).each do |source_item|
        target_item = copy_record!(
          source_item,
          PAYROLL_ITEM_CLEAR_COLUMNS.merge(
            company: target_company,
            pay_period: target,
            employee: maps.fetch(:employees).fetch(source_item.employee_id),
            # Committed payroll must retain the choice that applied when the
            # rehearsal was calculated. A nil committed value means paper
            # check, even when the employee is configured for direct deposit.
            payment_delivery_method: source_item.effective_payment_delivery_method
          )
        )
        source_item.payroll_item_earnings.order(:id).each do |earning|
          copy_record!(earning, payroll_item: target_item)
        end
        source_item.payroll_item_deductions.order(:id).each do |deduction|
          copy_record!(
            deduction,
            payroll_item: target_item,
            deduction_type: maps.fetch(:deduction_types).fetch(deduction.deduction_type_id),
            employee_loan: deduction.employee_loan_id && maps.fetch(:loans).fetch(deduction.employee_loan_id)
          )
        end
        source_item.payroll_item_field_entries.order(:id).each do |entry|
          copy_record!(
            entry,
            payroll_item: target_item,
            payroll_field_definition: entry.payroll_field_definition_id &&
              maps.fetch(:payroll_field_definitions).fetch(entry.payroll_field_definition_id)
          )
        end
      end
      source.pay_period_excluded_employees.order(:id).each do |excluded|
        copy_record!(excluded, pay_period: target, employee: maps.fetch(:employees).fetch(excluded.employee_id))
      end
      target
    end

    def apply_financial_effects!(periods)
      company_ytds = {}
      employee_ytds = {}
      periods.each do |period|
        year = period.pay_date.year
        company_ytd = company_ytds[year] ||= CompanyYtdTotal.find_by(company: target_company, year: year) ||
          CompanyYtdTotal.create_or_find_by!(company: target_company, year: year)
        period.payroll_items.includes(:employee, payroll_item_deductions: :deduction_type).order(:employee_id, :id).each do |item|
          PayrollCalculator.for(item.employee, item).apply_loan_payments!
          employee_ytd = employee_ytds[[ item.employee_id, year ]] ||=
            EmployeeYtdTotal.find_by(employee: item.employee, year: year) ||
              EmployeeYtdTotal.create_or_find_by!(employee: item.employee, year: year)
          employee_ytd.add_payroll_item!(item)
          company_ytd.add_payroll_item!(item)
        end
        PayrollLiabilityPostingService.post!(pay_period: period, actor: actor)
      end
    end

    def verify!(sources, targets)
      raise "Rehearsal promotion period-count verification failed" unless sources.length == targets.length

      sources.zip(targets).each do |source, target|
        source_totals = source.payroll_items.not_voided.pick(
          Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(gross_pay), 0)"), Arel.sql("COALESCE(SUM(net_pay), 0)")
        )
        target_totals = target.payroll_items.not_voided.pick(
          Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(gross_pay), 0)"), Arel.sql("COALESCE(SUM(net_pay), 0)")
        )
        raise "Rehearsal promotion payroll-total verification failed" unless source_totals == target_totals
      end
    end

    def copy_record!(source, overrides = {})
      attributes = source.attributes.except("id", "created_at", "updated_at")
      source.class.create!(attributes.merge(overrides.stringify_keys))
    end

    def audit_completed!(backup, sources, targets)
      AuditLog.record!(
        user: actor,
        organization_id: target_company.organization_id,
        company_id: target_company.id,
        action: "migration_promotion#completed",
        record_type: "companies",
        record_id: target_company.id,
        subject_name: target_company.name,
        metadata: {
          rehearsal_company_id: rehearsal.id,
          backup_company_id: backup.id,
          source_pay_period_ids: sources.map(&:id),
          promoted_pay_period_ids: targets.map(&:id),
          employee_count: target_company.employees.count,
          promoted_gross_pay: targets.sum { |period| period.payroll_items.sum(:gross_pay).to_d },
          promoted_net_pay: targets.sum { |period| period.payroll_items.sum(:net_pay).to_d }
        }
      )
    end
  end
end
