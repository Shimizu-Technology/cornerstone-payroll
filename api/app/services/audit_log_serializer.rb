# frozen_string_literal: true

class AuditLogSerializer
  def self.call(log, pay_period_subjects: {}, run_context_id: nil, employee_names: nil)
    presenter = AuditLogPresenter.new(log, pay_period_subjects: pay_period_subjects, run_context_id: run_context_id,
      employee_names: employee_names)
    {
      id: log.id,
      action: log.action,
      display_action: presenter.headline,
      display_subject: presenter.subject,
      summary: presenter.summary,
      detail_lines: PayRunActivityPhrase.detail_lines(log),
      event_category: log.event_category,
      record_type: log.record_type,
      record_id: log.record_id,
      subject_name: log.subject_name,
      user_id: log.user_id,
      actor_type: log.actor_type,
      actor_id: log.actor_id,
      user_name: log.actor_name.presence || log.user&.name,
      actor_email: log.actor_email.presence || log.user&.email,
      actor_role: log.actor_role.presence || log.user&.role,
      organization_id: log.organization_id,
      organization_name: log.organization&.name,
      company_id: log.company_id,
      company_name: log.company&.name,
      # A year-end filing download never shows an unkeyed file hash (FilingFileDigest).
      metadata: FilingFileDigest.redact_audit_metadata(log.action, log.metadata),
      ip_address: log.ip_address,
      user_agent: log.user_agent,
      request_id: log.request_id,
      created_at: log.created_at
    }
  end
end
