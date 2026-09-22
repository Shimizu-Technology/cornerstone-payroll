# frozen_string_literal: true

module TrainingReplay
  class Cloner
    PRACTICE_INPUT_COLUMNS = %w[
      employment_type pay_rate hours_worked overtime_hours holiday_hours pto_hours scheduled_hours
      reported_tips tips tips_paid_out cash_tips_reported service_charge_wages qualified_overtime_compensation
      bonus bonus_source imported_bonus salary_override non_taxable_pay custom_columns_data custom_deductions
      custom_earnings payroll_adjustments payment_delivery_method timekeeping_source timekeeping_context_snapshot
      withholding_tax_override withholding_tax_adjustment additional_withholding_override check_memo
    ].freeze
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
        raise ArgumentError, "This training workspace has already been prepared" unless company.migration_rehearsal_status == "pending"

        practice_sources = resolve_practice_sources!
        maps = TestWorkspace::SetupCloner.new(
          source_company: source_company,
          target_company: company,
          actor: actor,
          employee_lineage: true,
          loan_balance_on: practice_sources.first.pay_date
        ).call
        baseline_sources = baseline_sources_before(practice_sources.first)
        baseline_sources.each { |source| copy_baseline_period!(source, maps) }
        practice_sources.each { |source| copy_practice_period!(source, maps) }
        verify_copy!(baseline_sources, practice_sources)

        company.update!(migration_rehearsal_status: "ready", migration_rehearsal_completed_at: Time.current)
        audit_ready!(baseline_sources, practice_sources)
      end

      company
    rescue StandardError => e
      mark_failed!
      Rails.logger.error("Training replay clone failed for company #{company.id}: #{e.class}: #{e.message}")
      raise
    end

    private

    attr_reader :company, :source_company, :actor

    def validate!
      raise ArgumentError, "Target must be a training replay" unless company.training_replay?
      raise ArgumentError, "Source must be a live client" unless source_company&.live_payroll?
      raise ArgumentError, "Source and training workspace must belong to the same organization" unless company.organization_id == source_company.organization_id
      raise ArgumentError, "Actor no longer belongs to this organization" unless actor.organization_id == company.organization_id
    end

    def resolve_practice_sources!
      ids = Array(company.test_workspace_manifest["practice_source_pay_period_ids"]).map(&:to_i)
      periods = source_company.pay_periods.lock.where(id: ids).index_by(&:id)
      resolved = ids.filter_map { |id| periods[id] }
      valid = ids.length == Preview::PRACTICE_PERIOD_COUNT && resolved.length == ids.length &&
        resolved.all? { |period| period.status.in?(TrainingReplayBenchmark::SOURCE_STATUSES) && period.regular_cycle? && !period.voided? }
      raise ArgumentError, "The source payroll benchmarks changed before the training copy completed" unless valid

      resolved.sort_by { |period| [ period.start_date, period.end_date, period.pay_date, period.id ] }
    end

    def baseline_sources_before(first_practice)
      tax_year_start = first_practice.pay_date.beginning_of_year
      source_company.pay_periods
        .reportable_committed
        .regular_cycle
        .where(pay_date: tax_year_start..)
        .where("pay_date < ? OR (pay_date = ? AND id < ?)", first_practice.pay_date, first_practice.pay_date, first_practice.id)
        .period_chronological
        .to_a
    end

    def copy_baseline_period!(source, maps)
      target = create_period!(source, maps, role: "baseline", status: "approved")
      source.payroll_items.not_voided.order(:id).each do |source_item|
        target_item = copy_record!(
          source_item,
          company: company,
          pay_period: target,
          employee: maps.fetch(:employees).fetch(source_item.employee_id),
          **PAYROLL_ITEM_CLEAR_COLUMNS
        )
        copy_baseline_children!(source_item, target_item, maps)
      end
      target
    end

    def copy_practice_period!(source, maps)
      target = create_period!(source, maps, role: "practice", status: "draft")
      source.payroll_items.not_voided.order(:id).each do |source_item|
        attributes = source_item.attributes.slice(*PRACTICE_INPUT_COLUMNS)
        target_item = PayrollItem.create!(attributes.merge(
          company: company,
          pay_period: target,
          employee: maps.fetch(:employees).fetch(source_item.employee_id)
        ))
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
      BenchmarkSnapshot.capture!(company: company, pay_period: target, source_pay_period: source, actor: actor)
      target
    end

    def create_period!(source, maps, role:, status:)
      PayPeriod.create!(source.attributes.except(
        "id", "created_at", "updated_at", "company_id", "company_pay_schedule_id", "company_workweek_id",
        "corrects_pay_period_id", "source_pay_period_id", "superseded_by_id", "intake_stale_session_id",
        "tax_sync_idempotency_key", "test_workspace_source_pay_period_id", "test_workspace_role"
      ).merge(
        company: company,
        company_pay_schedule: source.company_pay_schedule_id && maps.fetch(:pay_schedules)[source.company_pay_schedule_id],
        company_workweek: source.company_workweek_id && maps.fetch(:workweeks)[source.company_workweek_id],
        status: status,
        parallel_run: true,
        correction_status: nil,
        cycle: "regular",
        corrects_pay_period_id: nil,
        source_pay_period_id: nil,
        superseded_by_id: nil,
        test_workspace_source_pay_period: source,
        test_workspace_role: role,
        created_by_id: actor.id,
        calculated_by_id: status == "approved" ? actor.id : nil,
        calculated_at: status == "approved" ? source.calculated_at || source.committed_at : nil,
        approved_by_id: status == "approved" ? actor.id : nil,
        approved_at: status == "approved" ? source.approved_at || source.committed_at : nil,
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

    def copy_baseline_children!(source_item, target_item, maps)
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

    def verify_copy!(baseline_sources, practice_sources)
      checks = {
        employees: [ source_company.employees.count, company.employees.count ],
        baseline_periods: [ baseline_sources.count, company.pay_periods.where(test_workspace_role: "baseline").count ],
        practice_periods: [ practice_sources.count, company.pay_periods.where(test_workspace_role: "practice").count ],
        baseline_items: [ baseline_sources.sum { |period| period.payroll_items.not_voided.count }, company.pay_periods.where(test_workspace_role: "baseline").joins(:payroll_items).count ],
        practice_items: [ practice_sources.sum { |period| period.payroll_items.not_voided.count }, company.pay_periods.where(test_workspace_role: "practice").joins(:payroll_items).count ],
        benchmark_snapshots: [ practice_sources.count, company.training_replay_benchmarks.count ]
      }
      mismatches = checks.select { |_key, values| values.first != values.last }
      raise "Training replay record-count verification failed: #{mismatches.keys.join(', ')}" if mismatches.any?
      if company.payroll_items.where.not(check_number: nil).exists?
        raise "Training replay safety verification failed: copied check numbers"
      end
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
        migration_rehearsal_error: "The training copy did not finish. No source data changed. Retry the isolated copy.",
        updated_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("Training replay failure status could not be saved for company #{company.id}: #{e.class}: #{e.message}")
    end

    def audit_ready!(baseline_sources, practice_sources)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "training_replay#ready",
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: {
          source_company_id: source_company.id,
          baseline_pay_period_count: baseline_sources.count,
          practice_source_pay_period_ids: practice_sources.map(&:id),
          employee_count: company.employees.count
        }
      )
    end
  end
end
