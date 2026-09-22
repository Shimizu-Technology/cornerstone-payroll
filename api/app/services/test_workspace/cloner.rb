# frozen_string_literal: true

module TestWorkspace
  class Cloner
    PAYROLL_ITEM_CLEAR_COLUMNS = TrainingReplay::Cloner::PAYROLL_ITEM_CLEAR_COLUMNS
    FAILURE_MESSAGE = "The test copy did not finish. No production data changed. Retry the isolated copy."

    def initialize(company:, actor:)
      @company = company
      @source_company = company.migration_source_company
      @actor = actor
    end

    def call
      validate!
      transaction_options = ApplicationRecord.connection.transaction_open? ? {} : { isolation: :repeatable_read }

      ApplicationRecord.transaction(**transaction_options) do
        company.lock!
        raise ArgumentError, "This test workspace has already been prepared" unless company.migration_rehearsal_status == "pending"

        source_periods = resolve_source_periods!
        maps = SetupCloner.new(
          source_company: source_company,
          target_company: company,
          actor: actor,
          employee_lineage: true,
          loan_balance_on: loan_balance_on(source_periods)
        ).call
        source_periods.each { |source| copy_baseline_period!(source, maps) }
        verify_copy!(source_periods)

        company.update!(migration_rehearsal_status: "ready", migration_rehearsal_completed_at: Time.current)
        audit_ready!(source_periods)
      end

      company
    rescue StandardError => e
      mark_failed!
      Rails.logger.error("Test workspace clone failed for company #{company.id}: #{e.class}: #{e.message}")
      raise
    end

    private

    attr_reader :company, :source_company, :actor

    def validate!
      raise ArgumentError, "Target must be a general test workspace" unless company.sandbox?
      raise ArgumentError, "Source must be a production client" unless source_company&.live_payroll?
      unless company.organization_id == source_company.organization_id
        raise ArgumentError, "Source and test workspace must belong to the same organization"
      end
      raise ArgumentError, "Actor no longer belongs to this organization" unless actor.organization_id == company.organization_id
    end

    def resolve_source_periods!
      ids = Array(company.test_workspace_manifest["copied_source_pay_period_ids"]).map(&:to_i)
      return [] if ids.empty?

      periods = source_company.pay_periods.lock.where(id: ids).index_by(&:id)
      resolved = ids.filter_map { |id| periods[id] }
      valid = resolved.length == ids.length && resolved.all? { |period| period.committed? && !period.voided? }
      raise ArgumentError, "The source payroll history changed before the test copy completed" unless valid

      resolved.sort_by { |period| [ period.start_date, period.end_date, period.pay_date, period.id ] }
    end

    def loan_balance_on(source_periods)
      source_periods.filter_map(&:pay_date).max&.next_day
    end

    def copy_baseline_period!(source, maps)
      target = create_period!(source, maps)
      source.payroll_items.not_voided.order(:id).each do |source_item|
        target_item = copy_record!(
          source_item,
          company: company,
          pay_period: target,
          employee: maps.fetch(:employees).fetch(source_item.employee_id),
          **PAYROLL_ITEM_CLEAR_COLUMNS
        )
        copy_item_children!(source_item, target_item, maps)
      end
      source.pay_period_excluded_employees.order(:id).each do |excluded|
        copy_record!(excluded, pay_period: target, employee: maps.fetch(:employees).fetch(excluded.employee_id))
      end
      target
    end

    def create_period!(source, maps)
      PayPeriod.create!(source.attributes.except(
        "id", "created_at", "updated_at", "company_id", "company_pay_schedule_id", "company_workweek_id",
        "corrects_pay_period_id", "source_pay_period_id", "superseded_by_id", "intake_stale_session_id",
        "tax_sync_idempotency_key", "test_workspace_source_pay_period_id", "test_workspace_role",
        "promotion_source_pay_period_id"
      ).merge(
        company: company,
        company_pay_schedule: source.company_pay_schedule_id && maps.fetch(:pay_schedules)[source.company_pay_schedule_id],
        company_workweek: source.company_workweek_id && maps.fetch(:workweeks)[source.company_workweek_id],
        status: "approved",
        parallel_run: true,
        correction_status: nil,
        corrects_pay_period_id: nil,
        source_pay_period_id: nil,
        superseded_by_id: nil,
        test_workspace_source_pay_period: source,
        test_workspace_role: "baseline",
        created_by_id: actor.id,
        calculated_by_id: actor.id,
        calculated_at: source.calculated_at || source.committed_at,
        approved_by_id: actor.id,
        approved_at: source.approved_at || source.committed_at,
        committed_by_id: nil,
        committed_at: nil,
        tax_sync_status: "pending",
        tax_sync_attempts: 0,
        tax_sync_last_error: nil,
        tax_synced_at: nil,
        voided_by_id: nil,
        voided_at: nil,
        void_reason: nil,
        intake_stale_at: nil,
        intake_stale_reason: nil,
        intake_stale_session_id: nil
      ))
    end

    def copy_item_children!(source_item, target_item, maps)
      source_item.payroll_item_earnings.order(:id).each do |earning|
        copy_record!(earning, payroll_item: target_item)
      end
      source_item.payroll_item_deductions.order(:id).each do |deduction|
        copy_record!(
          deduction,
          payroll_item: target_item,
          deduction_type: deduction.deduction_type_id && maps.fetch(:deduction_types).fetch(deduction.deduction_type_id),
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

    def verify_copy!(source_periods)
      checks = {
        employees: [ source_company.employees.count, company.employees.count ],
        payrolls: [ source_periods.count, company.pay_periods.where(test_workspace_role: "baseline").count ],
        payroll_items: [
          source_periods.sum { |period| period.payroll_items.not_voided.count },
          company.pay_periods.where(test_workspace_role: "baseline").joins(:payroll_items).count
        ]
      }
      mismatches = checks.select { |_key, values| values.first != values.last }
      raise "Test workspace record-count verification failed: #{mismatches.keys.join(', ')}" if mismatches.any?
      raise "Test workspace safety verification failed: copied check numbers" if company.payroll_items.where.not(check_number: nil).exists?
    end

    def copy_record!(source, **overrides)
      attributes = source.attributes.except("id", "created_at", "updated_at")
      source.class.create!(attributes.merge(overrides.stringify_keys))
    end

    def mark_failed!
      return unless company.persisted?

      company.reload
      return if company.migration_rehearsal_status == "ready"

      company.update_columns(
        migration_rehearsal_status: "failed",
        migration_rehearsal_error: FAILURE_MESSAGE,
        updated_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("Test workspace failure status could not be saved for company #{company.id}: #{e.class}: #{e.message}")
    end

    def audit_ready!(source_periods)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "test_workspace#ready",
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: {
          source_company_id: source_company.id,
          copied_source_pay_period_ids: source_periods.map(&:id),
          employee_count: company.employees.count
        }
      )
    end
  end
end
