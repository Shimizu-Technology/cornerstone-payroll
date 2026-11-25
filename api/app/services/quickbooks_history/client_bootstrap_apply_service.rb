# frozen_string_literal: true

module QuickbooksHistory
  class ClientBootstrapApplyService
    class StaleBootstrapAttempt < StandardError; end

    ACKNOWLEDGEMENT = "PREPARE CLEAN CLIENT EMPLOYEES"

    # w4_effective_on: only the demo seed passes it, so its W-4 elections cover
    # the native payroll that follows the imported history. Real clients keep
    # today's date.
    def initialize(bootstrap:, actor:, acknowledgement:, expected_apply_started_at: nil, w4_effective_on: nil)
      @bootstrap = bootstrap
      @actor = actor
      @acknowledgement = acknowledgement
      @expected_apply_started_at = expected_apply_started_at
      @w4_effective_on = w4_effective_on
    end

    def call
      ensure_authorized_actor!
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
      return bootstrap if bootstrap.applied?

      HistoricalClientBootstrap.transaction do
        # Keep the bounded roster write atomic: a partial employee roster is less safe than
        # briefly holding this per-company lock while at most the reviewed import limit is applied.
        bootstrap.company.lock!
        bootstrap.historical_import_batch.lock!
        bootstrap.lock!
        ensure_authorized_actor!(lock: true)
        next bootstrap if bootstrap.applied?
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
        flagged_emails = EmployeeContactValidator.marked_placeholder_emails(organization_id: bootstrap.company.organization_id)
        created_employee_count = 0
        blanked_email_count = plan.summary.fetch("blanked_contact_email_count", 0)
        blanked_phone_count = plan.summary.fetch("blanked_contact_phone_count", 0)
        plan.profiles.each do |profile|
          attrs, extra_blanked = sanitize_bootstrap_contact_attributes(
            profile.employee_attributes,
            flagged_emails: flagged_emails
          )
          blanked_email_count += 1 if extra_blanked.include?("email")
          blanked_phone_count += 1 if extra_blanked.include?("phone")

          employee = bootstrap.company.employees.create!(
            attrs.merge(created_by: actor, initial_compensation_source: "quickbooks_history", initial_compensation_actor: actor)
          )
          create_w4_election!(employee)
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
        record_audit!(
          plan,
          created_employee_count,
          blanked_contact_email_count: blanked_email_count,
          blanked_contact_phone_count: blanked_phone_count
        )
        bootstrap
      end
    end

    private

    attr_reader :bootstrap, :actor, :acknowledgement, :expected_apply_started_at

    def ensure_current_attempt!
      current_token = bootstrap.apply_started_at&.iso8601(6)
      return if bootstrap.pending? && current_token == expected_apply_started_at

      raise StaleBootstrapAttempt, "A newer clean-client preparation attempt superseded this job"
    end

    def ensure_authorized_actor!(lock: false)
      @actor = ClientBootstrapAuthorization.ensure_authorized!(actor: actor, lock: lock, company_id: bootstrap.company_id)
    end

    def create_wage_rates!(employee, wage_rates)
      wage_rates.each { |attributes| employee.employee_wage_rates.create!(attributes) }
    end

    def create_w4_election!(employee)
      return if employee.contractor?

      EmployeeW4ElectionChangeService.new(
        employee: employee,
        attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
          .merge(w4_effective_on: @w4_effective_on || Date.current),
        actor: actor,
        source: "quickbooks_history",
        reason: "Initial W-4 election prepared from retained QuickBooks setup"
      ).call!
    end

    def create_payroll_fields!(employee, payroll_fields, definition_cache)
      payroll_fields.each do |field|
        name = field.fetch(:name)
        definition = definition_cache[name] ||= bootstrap.company.payroll_field_definitions.find_by(name: name) ||
          bootstrap.company.payroll_field_definitions.create!(
            name: name,
            kind: field.fetch(:kind),
            tax_treatment: field.fetch(:tax_treatment),
            category: field.fetch(:category),
            amount_type: field.fetch(:amount_type),
            reporting_group: field.fetch(:reporting_group),
            show_in_payroll_grid: true,
            sort_order: bootstrap.company.payroll_field_definitions.maximum(:sort_order).to_i + 1
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
      attributes = {
        employee_id: employee.id,
        mapping_status: "exact_match",
        match_method: "quickbooks_client_bootstrap",
        match_confidence: 1,
        updated_at: Time.current
      }
      if bootstrap.historical_import_batch.applied?
        # Source facts stay immutable. Only the reviewed live-employee linkage may
        # be attached after apply and before the batch is locked.
        worker.update_columns(attributes)
      else
        worker.update!(attributes)
      end
      worker.historical_paychecks.update_all(employee_id: employee.id, updated_at: Time.current)
    end

    def sanitize_bootstrap_contact_attributes(raw_attributes, flagged_emails:)
      attrs = raw_attributes.dup
      raw_email = attrs[:email].presence
      raw_phone = attrs[:phone].presence
      blanked = []

      if raw_email.present? || raw_phone.present?
        candidate = bootstrap.company.employees.new(attrs.slice(:first_name, :last_name))
        result = EmployeeContactValidator.call(
          employee: candidate,
          company: bootstrap.company,
          email: raw_email.present? ? raw_email : :unchanged,
          phone: raw_phone.present? ? raw_phone : :unchanged,
          actor: nil,
          source: "import",
          flagged_emails: flagged_emails
        )
        if raw_email.present?
          if result.errors[:email].present?
            attrs[:email] = nil
            blanked << "email"
          else
            attrs[:email] = result.normalized_email
          end
        end
        if raw_phone.present?
          if result.errors[:phone].present?
            attrs[:phone] = nil
            blanked << "phone"
          else
            attrs[:phone] = result.normalized_phone
          end
        end
      end

      attrs[:email_verified_at] = nil
      attrs[:phone_confirmed_by_employee_at] = nil
      has_contact = EmployeeContactValidator::CONTACT_FIELDS.any? { |field| attrs[field].present? }
      attrs[:contact_source] = has_contact ? "import" : nil

      [ attrs, blanked ]
    end

    def record_audit!(plan, created_employee_count, blanked_contact_email_count: 0, blanked_contact_phone_count: 0)
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
          payroll_field_assignment_count: plan.summary.fetch("payroll_field_assignment_count"),
          blanked_contact_email_count: blanked_contact_email_count,
          blanked_contact_phone_count: blanked_contact_phone_count
        }
      )
    end
  end
end
