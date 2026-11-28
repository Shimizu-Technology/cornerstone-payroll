# frozen_string_literal: true

module EmployeeReadinessOverrides
  class Manage
    OPEN_PERIOD_STATUSES = %w[draft calculated approved].freeze

    def initialize(company_id:, employee_id:, actor:, verified:, impersonated:)
      @company_id = company_id
      @employee_id = employee_id
      @actor = actor
      @verified = verified
      @impersonated = impersonated
    end

    def preview(pay_period_id: nil, expires_on: nil)
      company = Company.find(@company_id)
      employee = employee_for(company)
      today = PayrollBusinessClock.today
      periods = open_periods(company)
      if pay_period_id.present? || expires_on.present?
        validate_scope!(pay_period_id, expires_on)
        period = target_period(company, pay_period_id, expiration_date(expires_on))
        checklist = target_checklist(employee, period, today)
        return {
          checklist: checklist.as_json,
          default_w4_acknowledgement_required: default_withholding?(employee, checklist)
        }
      end

      {
        today: today.iso8601,
        latest_expiration: (today + 30.days).iso8601,
        pay_periods: periods.order(:pay_date, :id).as_json(only: %i[id start_date end_date pay_date]),
        active_overrides: employee.employee_readiness_overrides.active
          .where(pay_period_id: periods.select(:id)).or(
            employee.employee_readiness_overrides.active.where(pay_period_id: nil, expires_on: today..)
          ).order(:id).as_json(only: %i[id pay_period_id expires_on])
      }
    end

    def grant!(reason:, pay_period_id: nil, expires_on: nil, default_w4_acknowledged: false)
      with_company_lock do |company|
        validate_scope!(pay_period_id, expires_on)
        expires_on = expiration_date(expires_on)
        period = target_period(company, pay_period_id, expires_on, lock: true)
        employee = employee_for(company)
        snapshot = {}
        override = nil
        persist_override = ->(entry) do
          override = EmployeeReadinessOverride.create!(
            company: company, employee: employee, pay_period_id: pay_period_id.presence && period.id,
            expires_on: expires_on, missing_items_snapshot: snapshot.fetch(:missing_items),
            default_w4_acknowledged: default_w4_acknowledged == true, reason: entry.reason,
            granted_by: entry.actor, granted_at: Time.current, admin_override: entry
          )
          if snapshot[:default_withholding]
            election = default_w4_election!(employee, override, snapshot.fetch(:w4_on), entry)
            override.update!(default_w4_election: election)
          end
        end

        perform!(company, employee, action: "employee_readiness_override#grant", reason: reason,
          snapshot: -> { snapshot.dup }, after_record: persist_override) do
          checklist = validate_grant!(employee, period, pay_period_id)
          default_withholding = default_withholding?(employee, checklist)
          if default_withholding && default_w4_acknowledged != true
            raise ArgumentError, "Acknowledge Single withholding with no adjustments when Form W-4 is missing"
          end

          snapshot.merge!(pay_period_id: pay_period_id.presence && period.id, expires_on: expires_on,
            missing_items: checklist.missing_keys, default_withholding: default_withholding, w4_on: checklist.w4_on)
        end
        override
      end
    end

    def revoke!(override_id:, reason:)
      with_company_lock do |company|
        employee = employee_for(company)
        override = employee.employee_readiness_overrides.where(company: company).find(override_id)
        period = company.pay_periods.lock.find(override.pay_period_id) if override.pay_period_id
        perform!(company, employee, action: "employee_readiness_override#revoke", reason: reason,
          snapshot: -> { override.reload.attributes.slice("id", "pay_period_id", "expires_on", "revoked_at", "revoked_by_id") }) do |actor, normalized_reason|
          override.lock!
          if period && (period.committed? || period.committed_at.present?)
            raise ArgumentError, "An override pinned to a committed pay period cannot be revoked"
          end
          if override.revoked_at? || (override.expires_on && override.expires_on < PayrollBusinessClock.today)
            raise ArgumentError, "Only active overrides can be revoked"
          end

          override.update!(revoked_by: actor, revoked_at: Time.current, revoke_reason: normalized_reason)
          override
        end
      end
    end

    def clear_gate!(reason:)
      with_company_lock do |company|
        employee = employee_for(company)
        perform!(company, employee, action: "employee_readiness_gate#clear", reason: reason,
          snapshot: -> { { "readiness_gate_enforced" => employee.readiness_gate_enforced? } }) do
          raise ArgumentError, "This employee's readiness gate is already clear" unless employee.readiness_gate_enforced?

          employee.update!(readiness_gate_enforced: false)
          employee
        end
      end
    end

    private

    def with_company_lock
      ApplicationRecord.transaction do
        company = Company.lock.find(@company_id)
        unless StaffEmployeeLifecycle.available?(company)
          raise AdminOverrideService::AccessDenied, "Client-managed employee lifecycle is not enabled for this company."
        end

        yield company
      end
    end

    def employee_for(company)
      company.employees.find(@employee_id)
    end

    def perform!(company, employee, **options, &block)
      AdminOverrideService.perform!(company: company, subject: employee, actor: @actor,
        capability: :override_employee_readiness, fresh_required: true, verified: @verified,
        impersonated: @impersonated, **options, &block)
    end

    def validate_scope!(pay_period_id, expires_on)
      return if pay_period_id.present? ^ expires_on.present?

      raise ArgumentError, "Specify a pay period or an expiration date"
    end

    def expiration_date(value)
      return if value.blank?

      date = Date.iso8601(value.to_s)
      today = PayrollBusinessClock.today
      return date if date.between?(today, today + 30.days)

      raise ArgumentError, "Expiration must be between today and 30 days from today"
    rescue Date::Error
      raise ArgumentError, "Provide an expiration date in YYYY-MM-DD format"
    end

    def open_periods(company)
      company.pay_periods.where(status: OPEN_PERIOD_STATUSES)
        .where("correction_status IS NULL OR correction_status <> ?", "voided")
    end

    def target_period(company, pay_period_id, expires_on, lock: false)
      if pay_period_id.present?
        periods = company.pay_periods
        periods = periods.lock if lock
        period = periods.find(pay_period_id)
        unless period.status.in?(OPEN_PERIOD_STATUSES) && !period.voided?
          raise ArgumentError, "Choose an open pay period"
        end
        return period
      end

      periods = company.pay_periods.where(status: %w[draft calculated], cycle: "regular", run_purpose: "regular",
        correction_status: nil, test_workspace_role: nil, parallel_run: false)
        .where("pay_date <= ?", expires_on).order(:pay_date, :id)
      periods = periods.lock if lock
      periods.first
    end

    def validate_grant!(employee, period, pay_period_id)
      raise ArgumentError, "This employee does not have a payroll readiness gate" unless employee.readiness_gate_enforced?

      checklist = target_checklist(employee, period, PayrollBusinessClock.today)
      raise ArgumentError, "This employee has no missing readiness items" if checklist.ready?
      if pay_period_id.present? && employee.employee_readiness_overrides.active.exists?(pay_period_id: period.id)
        raise ArgumentError, "An active override already exists for this pay period"
      end

      checklist
    end

    def target_checklist(employee, period, today)
      return EmployeeReadinessEvaluator.for_pay_period(employee, period) if period

      EmployeeReadinessEvaluator.evaluate(employee, rates_on: today, w4_on: today)
    end

    def default_withholding?(employee, checklist)
      employee.w2_employee? && checklist.missing_keys.include?("tax_form")
    end

    def default_w4_election!(employee, override, target_pay_date, entry)
      current = employee.w4_election_on(target_pay_date)
      return current if current&.source == "default_withholding"
      if current && current.w4_form_version.to_i >= Employee::MIN_SUPPORTED_W4_FORM_VERSION
        raise ArgumentError, "Record a valid Form W-4 before granting this override"
      end

      # Shadow the invalid election on its effective date if it already governs the target payday.
      effective_on = [ target_pay_date, employee.hire_date ].compact.min
      effective_on = [ effective_on, current.effective_on ].max if current
      EmployeeW4ElectionChangeService.new(employee: employee, actor: entry.actor, source: "default_withholding",
        reason: entry.reason, attributes: EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.merge(
          w4_effective_on: effective_on,
          w4_source_reference: "Admin readiness override ##{override.id} — IRS Pub 15-T default (Single, no adjustments)"
        )).call!
    end
  end
end
