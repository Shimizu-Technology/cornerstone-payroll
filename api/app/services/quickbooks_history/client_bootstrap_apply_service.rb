# frozen_string_literal: true

module QuickbooksHistory
  class ClientBootstrapApplyService
    class StaleBootstrapAttempt < StandardError; end

    ACKNOWLEDGEMENT = "PREPARE CLEAN CLIENT EMPLOYEES"

    def initialize(bootstrap:, actor:, acknowledgement:, expected_apply_started_at: nil)
      @bootstrap = bootstrap
      @actor = actor
      @acknowledgement = acknowledgement
      @expected_apply_started_at = expected_apply_started_at
    end

    def call
      ensure_authorized_actor!
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
      return bootstrap if bootstrap.applied?

      result = nil
      HistoricalClientBootstrap.transaction do
        bootstrap.historical_import_batch.lock!
        bootstrap.lock!
        return bootstrap if bootstrap.applied?
        ensure_current_attempt! if expected_apply_started_at
        unless bootstrap.previewed? || bootstrap.pending? || bootstrap.failed?
          raise ArgumentError, "The clean-client employee setup is not ready to apply"
        end

        plan = ClientBootstrapPlan.new(batch: bootstrap.historical_import_batch).call
        raise ArgumentError, plan.errors.join("; ") unless plan.ready?
        unless ActiveSupport::SecurityUtils.secure_compare(plan.digest, bootstrap.plan_digest)
          raise ArgumentError, "The QuickBooks client-preparation preview changed. Build a new preview and review it again."
        end

        definition_cache = {}
        created_employee_count = 0
        plan.profiles.each do |profile|
          employee = bootstrap.company.employees.create!(profile.employee_attributes)
          create_wage_rates!(employee, profile.wage_rates)
          create_payroll_fields!(employee, profile.payroll_fields, definition_cache)
          link_worker!(profile.worker, employee)
          created_employee_count += 1
        end

        bootstrap.update!(
          status: "applied",
          apply_error: nil,
          applied_at: Time.current,
          applied_by: actor
        )
        record_audit!(plan, created_employee_count)
        result = bootstrap
      end
      result
    end

    private

    attr_reader :bootstrap, :actor, :acknowledgement, :expected_apply_started_at

    def ensure_current_attempt!
      current_token = bootstrap.apply_started_at&.iso8601(6)
      return if bootstrap.pending? && current_token == expected_apply_started_at

      raise StaleBootstrapAttempt, "A newer clean-client preparation attempt superseded this job"
    end

    def ensure_authorized_actor!
      ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: bootstrap.company_id)
    end

    def create_wage_rates!(employee, wage_rates)
      wage_rates.each { |attributes| employee.employee_wage_rates.create!(attributes) }
    end

    def create_payroll_fields!(employee, payroll_fields, definition_cache)
      payroll_fields.each do |field|
        definition = definition_cache[field.fetch(:name)] ||= bootstrap.company.payroll_field_definitions.create!(
          name: field.fetch(:name),
          kind: field.fetch(:kind),
          tax_treatment: field.fetch(:tax_treatment),
          category: field.fetch(:category),
          amount_type: field.fetch(:amount_type),
          reporting_group: field.fetch(:reporting_group),
          show_in_payroll_grid: true,
          sort_order: definition_cache.size
        )
        ensure_definition_matches!(definition, field)
        employee.employee_payroll_fields.create!(
          payroll_field_definition: definition,
          amount: field.fetch(:amount),
          percentage: field.fetch(:percentage),
          active: true,
          notes: "Prepared from retained QuickBooks employee setup; review before first committed payroll"
        )
      end
    end

    def ensure_definition_matches!(definition, field)
      expected = field.slice(:kind, :tax_treatment, :category, :amount_type, :reporting_group).stringify_keys
      actual = definition.attributes.slice(*expected.keys)
      return if actual == expected

      raise ArgumentError, "QuickBooks payroll item '#{field.fetch(:name)}' has conflicting setup across employees"
    end

    def link_worker!(worker, employee)
      worker.update!(
        employee: employee,
        mapping_status: "exact_match",
        match_method: "quickbooks_client_bootstrap",
        match_confidence: 1
      )
      worker.historical_paychecks.update_all(employee_id: employee.id, updated_at: Time.current)
    end

    def record_audit!(plan, created_employee_count)
      AuditLog.record!(
        user: actor,
        organization_id: bootstrap.company.organization_id,
        company_id: bootstrap.company_id,
        action: "historical_imports#apply_client_bootstrap",
        record_type: "historical_client_bootstraps",
        record_id: bootstrap.id,
        subject_name: bootstrap.historical_import_batch.source_label,
        metadata: {
          historical_import_batch_id: bootstrap.historical_import_batch_id,
          plan_digest: plan.digest,
          created_employee_count: created_employee_count,
          active_employee_count: plan.summary.fetch("active_employee_count"),
          wage_rate_count: plan.summary.fetch("wage_rate_count"),
          payroll_field_assignment_count: plan.summary.fetch("payroll_field_assignment_count")
        }
      )
    end
  end
end
