# frozen_string_literal: true

require "digest"

module MigrationRehearsal
  class Cloner
    FINANCIAL_COLUMNS = %w[
      gross_pay pretax_deductions employee_taxes after_tax_deductions net_pay employer_taxes
      employer_contributions total_payroll_cost federal_income_tax social_security_tax medicare_tax
    ].freeze

    def initialize(company:, source_batch:, actor:, storage: R2StorageService.new)
      @company = company
      @source_batch = source_batch
      @source_company = source_batch.company
      @actor = actor
      @storage = storage
      @uploaded_keys = []
    end

    def call
      validate!

      transaction_options = ApplicationRecord.connection.transaction_open? ? {} : { isolation: :repeatable_read }
      ApplicationRecord.transaction(**transaction_options) do
        company.lock!
        raise ArgumentError, "This migration rehearsal has already been prepared" unless company.migration_rehearsal_status == "pending"

        # Cleanup must happen after the row lock. A duplicate background job
        # must not delete files written by the job that completed first.
        cleanup_existing_uploads!
        maps = copy_company_setup!
        copy_staff_assignments!
        target_batch = copy_historical_archive!(maps.fetch(:employees))
        verify_copy!(target_batch)
        company.update!(migration_rehearsal_status: "ready", migration_rehearsal_completed_at: Time.current)

        audit_ready!(target_batch)
      end

      company
    rescue StandardError => e
      cleanup_uploads!
      mark_failed!
      Rails.logger.error("Migration rehearsal clone failed for company #{company.id}: #{e.class}: #{e.message}")
      raise
    end

    private

    attr_reader :company, :source_company, :source_batch, :actor, :storage, :uploaded_keys

    def validate!
      raise ArgumentError, "Target must be a migration rehearsal" unless company.migration_rehearsal?
      raise ArgumentError, "Migration rehearsal source changed" unless company.migration_source_company_id == source_company.id
      raise ArgumentError, "Migration rehearsal import source changed" unless company.migration_source_batch_id == source_batch.id
      raise ArgumentError, "Source and rehearsal must belong to the same organization" unless company.organization_id == source_company.organization_id
      raise ArgumentError, "Source must be a live client" unless source_company.live_payroll?
      raise ArgumentError, "Historical import must be locked" unless source_batch.locked?
      raise ArgumentError, "Historical import source files are incomplete" unless source_batch.source_files_complete_and_verified?
      raise ArgumentError, "Actor no longer belongs to this organization" unless actor.organization_id == company.organization_id
    end

    def copy_company_setup!
      department_map = copy_collection(source_company.departments, Department, company: company)
      deduction_type_map = copy_collection(source_company.deduction_types, DeductionType, company: company)
      field_definition_map = copy_collection(source_company.payroll_field_definitions, PayrollFieldDefinition, company: company)

      copy_collection(source_company.company_pay_schedules, CompanyPaySchedule, company: company)
      copy_collection(source_company.company_workweeks, CompanyWorkweek, company: company)

      employee_map = {}
      source_company.employees.order(:id).each do |source|
        employee_map[source.id] = copy_record!(
          source,
          company: company,
          department: source.department_id && department_map.fetch(source.department_id),
          previous_employee_id: nil,
          portal_pending_approval: false
        )
      end
      source_company.employees.where.not(previous_employee_id: nil).find_each do |source|
        employee_map.fetch(source.id).update!(previous_employee: employee_map.fetch(source.previous_employee_id))
      end
      # Preserve the source review queue exactly. Ordinary employee saves may
      # auto-resolve an imported item when its field is populated; cloning is
      # an evidence copy, not a new Cornerstone review decision.
      source_company.employees.order(:id).each do |source|
        employee_map.fetch(source.id).update_columns(
          configuration_source: source.configuration_source,
          configuration_review_status: source.configuration_review_status,
          configuration_review_items: source.configuration_review_items,
          updated_at: Time.current
        )
      end

      source_company.employees.order(:id).each do |source|
        target = employee_map.fetch(source.id)
        copy_collection(source.employee_wage_rates, EmployeeWageRate, employee: target)
        copy_collection(source.employee_w4_elections, EmployeeW4Election, company: company, employee: target)
        copy_collection(source.employee_work_profiles, EmployeeWorkProfile, company: company, employee: target)
        copy_collection(source.employee_status_events, EmployeeStatusEvent, company: company, employee: target)
        copy_collection(source.employee_tipped_occupations, EmployeeTippedOccupation, employee: target)
        source.employee_deductions.each do |deduction|
          copy_record!(deduction, employee: target, deduction_type: deduction_type_map.fetch(deduction.deduction_type_id))
        end
      end

      loan_map = {}
      source_company.employee_loans.order(:id).each do |loan|
        loan_map[loan.id] = copy_record!(
          loan,
          company: company,
          employee: employee_map.fetch(loan.employee_id),
          deduction_type: loan.deduction_type_id && deduction_type_map.fetch(loan.deduction_type_id)
        )
      end

      EmployeePayrollField.joins(:employee).where(employees: { company_id: source_company.id }).order(:id).each do |field|
        copy_record!(
          field,
          employee: employee_map.fetch(field.employee_id),
          payroll_field_definition: field_definition_map.fetch(field.payroll_field_definition_id),
          employee_loan: field.employee_loan_id && loan_map.fetch(field.employee_loan_id)
        )
      end

      { employees: employee_map }
    end

    def copy_staff_assignments!
      CompanyAssignment.where(company_id: source_company.id).find_each do |assignment|
        next unless assignment.user.staff_member?

        CompanyAssignment.find_or_create_by!(user_id: assignment.user_id, company: company)
      end
    end

    def copy_historical_archive!(employee_map)
      target_batch = copy_record!(source_batch, company: company)
      source_file_map = copy_source_files!(target_batch)
      worker_map = {}
      source_batch.historical_workers.order(:id).each do |worker|
        worker_map[worker.id] = copy_record!(
          worker,
          company: company,
          historical_import_batch: target_batch,
          employee: worker.employee_id && employee_map.fetch(worker.employee_id)
        )
      end

      period_map = copy_collection(
        source_batch.historical_pay_periods,
        HistoricalPayPeriod,
        company: company,
        historical_import_batch: target_batch
      )
      paycheck_map = {}
      source_batch.historical_paychecks.order(:id).each do |paycheck|
        paycheck_map[paycheck.id] = copy_record!(
          paycheck,
          company: company,
          historical_import_batch: target_batch,
          historical_pay_period: period_map.fetch(paycheck.historical_pay_period_id),
          historical_worker: worker_map.fetch(paycheck.historical_worker_id),
          employee: paycheck.employee_id && employee_map.fetch(paycheck.employee_id)
        )
      end

      source_batch.historical_tax_wage_reports.order(:id).each do |report|
        copy_record!(
          report,
          company: company,
          historical_import_batch: target_batch,
          historical_import_source_file: source_file_map.fetch(report.historical_import_source_file_id)
        )
      end

      copy_record!(
        source_batch.historical_import_cutover_review,
        company: company,
        historical_import_batch: target_batch
      ) if source_batch.historical_import_cutover_review

      bootstrap = if source_batch.historical_client_bootstrap
        copy_record!(source_batch.historical_client_bootstrap, company: company, historical_import_batch: target_batch)
      end
      bridge_map = copy_ytd_bridges!(target_batch, bootstrap, employee_map)
      copy_adjustments!(paycheck_map, bridge_map)
      target_batch
    end

    def copy_source_files!(target_batch)
      source_batch.historical_import_source_files.in_manifest_order.each_with_object({}) do |source_file, result|
        bytes = storage.download_with_limit(
          source_file.storage_key,
          max_bytes: QuickbooksHistory::BundleParser::MAX_FILE_BYTES
        )
        validate_source_bytes!(source_file, bytes)
        key = "#{storage_prefix}/source-#{source_file.position.to_s.rjust(2, '0')}#{File.extname(source_file.original_filename).downcase}"
        storage.upload(key, bytes, content_type: source_file.content_type)
        uploaded_keys << key
        validate_source_bytes!(source_file, storage.download_with_limit(key, max_bytes: QuickbooksHistory::BundleParser::MAX_FILE_BYTES))

        result[source_file.id] = copy_record!(
          source_file,
          company: company,
          historical_import_batch: target_batch,
          storage_key: key,
          uploaded_by: actor,
          verification_status: "verified",
          verified_at: Time.current,
          verification_error: nil
        )
      end
    end

    def copy_ytd_bridges!(target_batch, bootstrap, employee_map)
      return {} unless bootstrap

      bridge_map = {}
      source_batch.historical_ytd_bridges.order(:revision, :id).each do |bridge|
        target = copy_record!(
          bridge,
          company: company,
          historical_import_batch: target_batch,
          historical_client_bootstrap: bootstrap,
          supersedes_historical_ytd_bridge: bridge.supersedes_historical_ytd_bridge_id && bridge_map.fetch(bridge.supersedes_historical_ytd_bridge_id)
        )
        bridge_map[bridge.id] = target
        bridge.historical_employee_ytd_balances.order(:id).each do |balance|
          copy_record!(
            balance,
            company: company,
            historical_ytd_bridge: target,
            employee: employee_map.fetch(balance.employee_id)
          )
        end
      end
      bridge_map
    end

    def copy_adjustments!(paycheck_map, bridge_map)
      source_adjustments = HistoricalPaycheckAdjustment.where(historical_paycheck_id: paycheck_map.keys).order(:id)
      adjustment_map = {}
      source_adjustments.each do |adjustment|
        adjustment_map[adjustment.id] = copy_record!(
          adjustment,
          company: company,
          historical_paycheck: paycheck_map.fetch(adjustment.historical_paycheck_id),
          reverses_adjustment: adjustment.reverses_adjustment_id && adjustment_map.fetch(adjustment.reverses_adjustment_id)
        )
      end
      HistoricalPaycheckAdjustmentEvent.where(historical_paycheck_adjustment_id: adjustment_map.keys).order(:id).each do |event|
        copy_record!(
          event,
          company: company,
          historical_paycheck_adjustment: adjustment_map.fetch(event.historical_paycheck_adjustment_id),
          historical_ytd_bridge: event.historical_ytd_bridge_id && bridge_map.fetch(event.historical_ytd_bridge_id)
        )
      end
    end

    def verify_copy!(target_batch)
      checks = {
        employees: [ source_company.employees.count, company.employees.count ],
        employee_deductions: [ employee_relation(EmployeeDeduction, source_company).count, employee_relation(EmployeeDeduction, company).count ],
        employee_payroll_fields: [ employee_relation(EmployeePayrollField, source_company).count, employee_relation(EmployeePayrollField, company).count ],
        employee_loans: [ source_company.employee_loans.count, company.employee_loans.count ],
        periods: [ source_batch.historical_pay_periods.count, target_batch.historical_pay_periods.count ],
        paychecks: [ source_batch.historical_paychecks.count, target_batch.historical_paychecks.count ],
        source_files: [ source_batch.historical_import_source_files.count, target_batch.historical_import_source_files.count ],
        workers: [ source_batch.historical_workers.count, target_batch.historical_workers.count ],
        tax_wage_reports: [ source_batch.historical_tax_wage_reports.count, target_batch.historical_tax_wage_reports.count ],
        ytd_bridges: [ source_batch.historical_ytd_bridges.count, target_batch.historical_ytd_bridges.count ],
        ytd_balances: [ ytd_balance_count(source_batch), ytd_balance_count(target_batch) ],
        historical_adjustments: [ adjustment_count(source_batch), adjustment_count(target_batch) ]
      }
      mismatches = checks.select { |_key, values| values.first != values.last }
      raise "Migration rehearsal record-count verification failed: #{mismatches.keys.join(', ')}" if mismatches.any?
      raise "Migration rehearsal source-file verification failed" unless target_batch.source_files_complete_and_verified?

      source_totals = historical_totals(source_batch)
      target_totals = historical_totals(target_batch)
      raise "Migration rehearsal payroll-total verification failed" unless source_totals == target_totals
    end

    def historical_totals(batch)
      FINANCIAL_COLUMNS.index_with { |column| batch.historical_paychecks.sum(column).to_d }
    end

    def employee_relation(model, target_company)
      model.joins(:employee).where(employees: { company_id: target_company.id })
    end

    def ytd_balance_count(batch)
      HistoricalEmployeeYtdBalance.where(historical_ytd_bridge_id: batch.historical_ytd_bridges.select(:id)).count
    end

    def adjustment_count(batch)
      HistoricalPaycheckAdjustment.where(historical_paycheck_id: batch.historical_paychecks.select(:id)).count
    end

    def copy_collection(scope, target_class, **overrides)
      scope.order(:id).each_with_object({}) do |source, result|
        raise ArgumentError, "Unexpected rehearsal source type" unless source.is_a?(target_class)

        result[source.id] = copy_record!(source, **overrides)
      end
    end

    def copy_record!(source, **overrides)
      attributes = source.attributes.except("id", "created_at", "updated_at")
      source.class.create!(attributes.merge(overrides.stringify_keys))
    end

    def validate_source_bytes!(source_file, bytes)
      valid = bytes.present? && bytes.bytesize == source_file.byte_size &&
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(bytes), source_file.sha256)
      raise "Retained source file #{source_file.position + 1} failed integrity verification" unless valid
    end

    def storage_prefix
      @storage_prefix ||= "historical-payroll/company-#{company.id}/migration-rehearsal/batch-#{source_batch.id}"
    end

    def cleanup_existing_uploads!
      storage.list(prefix: storage_prefix).each { |key| storage.delete(key) }
    end

    def cleanup_uploads!
      uploaded_keys.each { |key| storage.delete(key) }
    rescue StandardError => e
      Rails.logger.error("Migration rehearsal storage cleanup failed for company #{company.id}: #{e.class}: #{e.message}")
    end

    def mark_failed!
      return unless company.persisted?

      company.reload
      return if company.migration_rehearsal_status == "ready"

      company.update_columns(
        migration_rehearsal_status: "failed",
        migration_rehearsal_error: "The rehearsal copy did not finish. No source data changed. Retry the verified copy.",
        updated_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("Migration rehearsal failure status could not be saved for company #{company.id}: #{e.class}: #{e.message}")
    end

    def audit_ready!(target_batch)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "migration_rehearsal#ready",
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: {
          source_company_id: source_company.id,
          source_historical_import_batch_id: source_batch.id,
          historical_import_batch_id: target_batch.id,
          bundle_digest: target_batch.bundle_digest,
          imported_paycheck_count: target_batch.historical_paychecks.count,
          source_file_count: target_batch.historical_import_source_files.count
        }
      )
    end
  end
end
