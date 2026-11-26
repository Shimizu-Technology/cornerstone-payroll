# frozen_string_literal: true

class AdminOverrideService
  class AccessDenied < StandardError; end

  PERIOD_SNAPSHOT_FIELDS = %w[status correction_status voided_at voided_by_id void_reason
    superseded_by_id start_date end_date pay_date committed_by_id approved_by_id].freeze

  def self.reason!(value)
    reason = value.is_a?(String) ? value.strip : ""
    raise ArgumentError, "Enter a reason between 10 and 1,000 characters" unless reason.length.between?(10, 1000)

    reason
  end

  def self.payroll_confirmation(period, company: period.company)
    "#{company.name} / #{period.start_date} to #{period.end_date}"
  end

  def self.rollback_payroll!(pay_period:, actor:, verified:, impersonated:, reason:, confirmation:,
    unpaid_acknowledgement:, reopen: false, scope_attributes: {}, acknowledge_later_runs: false)
    verify_session!(verified: verified, impersonated: impersonated)

    reason = reason!(reason)
    unless unpaid_acknowledgement == true
      raise ArgumentError, "Confirm that all employee and tax payments remain unissued and unpaid, and prepared paper checks will be destroyed"
    end
    PayPeriod.transaction(requires_new: true) do
      company = Company.lock.find(pay_period.company_id)
      actor = authorize!(actor: actor, company: company)
      period = PayPeriod.lock.find(pay_period.id)
      unless confirmation == payroll_confirmation(period, company: company)
        raise ArgumentError, "Type the client name and period exactly as shown"
      end

      if period.voided?
        raise PayPeriodCorrectionService::AlreadyVoidedError, "This pay period has already been voided"
      end

      preflight = PayrollRevisionPaymentPreflight.new(pay_period: period, lock: true).ensure_eligible!(reopen: reopen)
      totals = AuditRecordSnapshot.pay_period_business_summary(period)
      record!(
        company: company, subject: period, actor: actor, reason: reason,
        action: reopen ? "reopen_unpaid" : "void_pay_period",
        preflight: preflight.result.merge(
          employee_checks: preflight.result.fetch(:employee_checks).map { |check| check.except(:payee, :amount) },
          other_payments: preflight.result.fetch(:other_payments).map { |check| check.except(:payee, :amount) },
          unpaid_acknowledgement: unpaid_acknowledgement, acknowledge_later_runs: acknowledge_later_runs
        ),
        snapshot: -> { period.attributes.slice(*PERIOD_SNAPSHOT_FIELDS) },
        audit_metadata: { business_summary: totals }, notify: PortalNotifications.method(:payroll_rollback!),
        self_override: [ period.created_by_id, period.approved_by_id, period.committed_by_id ].include?(actor.id)
      ) do
        if reopen
          PayPeriodCorrectionService.reopen_unpaid!(pay_period: period, actor: actor, reason: reason, scope_attributes: scope_attributes)
        else
          PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: reason,
            acknowledge_later_runs: acknowledge_later_runs)
        end
      end
    end
  end

  private_class_method def self.verify_session!(verified:, impersonated:)
    raise AccessDenied, "Exit Sign in as before using an admin override" if impersonated || Current.view_as_grant.present?
    raise AccessDenied, "A fresh sign-in is required" unless verified == true
  end

  private_class_method def self.authorize!(actor:, company:)
    actor = User.lock.find_by(id: actor&.id)
    company.company_assignments.where(user_id: actor&.id).lock.load
    unless StaffRolePolicy.allowed?(actor, :break_glass, company: company) &&
        actor.payroll_access_allowed? && actor.can_access_company?(company.id) &&
        TestWorkspaceAccessPolicy.allowed?(user: actor, company: company, request_method: "POST", capability: :break_glass)
      raise AccessDenied, "Admin access required"
    end
    actor
  end

  # Called within the locked business transaction. Other privileged actions can
  # supply their own snapshots, preflight and result notification.
  private_class_method def self.record!(company:, subject:, actor:, reason:, action:, preflight:, self_override:, snapshot:, audit_metadata:, notify:)
    before = snapshot.call
    result = yield
    subject.reload
    after = snapshot.call
    entry = AdminOverride.create!(company: company, subject: subject, actor: actor,
      real_user: Current.real_user, reason: reason, action: action, preflight_result: preflight,
      before_snapshot: before, after_snapshot: after, self_override: self_override)
    changed_fields = before.keys.select { |field| before[field] != after[field] }
    AuditLog.record!(user: actor, company_id: company.id, organization_id: company.organization_id, action: action,
      record_type: subject.class.name, record_id: subject.id, subject_name: AuditRecordSnapshot.subject_name(subject),
      metadata: audit_metadata.merge(admin_override_id: entry.id, reason: reason, before_values: before, after_values: after,
        changed_fields: changed_fields, self_override: self_override))
    notify.call(entry)
    result
  end
end
