# frozen_string_literal: true

module PayrollSubmissions
  # Named Activity History entries for a period. Recorded inside the domain
  # transaction, so a failed audit write rolls the action back.
  module Audit
    ACTIONS = %w[
      payroll_submissions#create
      payroll_submission_periods#acknowledge
      payroll_submission_periods#start_review
      payroll_submission_periods#import
      payroll_submission_periods#resolve_source
      payroll_submissions#open_import
      payroll_submission_periods#approve
      payroll_submission_periods#request_changes
      payroll_submission_periods#mark_paid
      payroll_submission_drafts#create
      payroll_submission_drafts#post
    ].freeze

    def self.record!(actor:, period:, action:, metadata: {}, request_context: {})
      AuditLog.record!(user: actor, company_id: period.company_id, action: action,
        record_type: "payroll_submission_periods", record_id: period.id,
        subject_name: "#{period.label} payroll",
        metadata: { period_start: period.start_date.iso8601, period_end: period.end_date.iso8601 }.merge(metadata),
        **request_context.slice(:ip_address, :user_agent))
    end

    def self.submission_metadata(submission)
      links = submission.submission_documents.to_a
      { submission_id: submission.id, revision: submission.revision, document_ids: links.map(&:client_document_id),
        document_roles: links.map(&:role).tally, workbook_choice: submission.workbook_choice, no_changes: submission.no_changes, change_count: submission.change_rows.size }
    end

    def self.feed(period)
      AuditLog.where(company_id: period.company_id, record_type: "payroll_submission_periods", record_id: period.id, action: ACTIONS)
        .newest_first
    end
  end
end
