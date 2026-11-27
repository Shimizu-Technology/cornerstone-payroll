# frozen_string_literal: true

# The email notice for one posted employee document (M4-5), and what the
# provider later reports about its delivery. "sent" means the provider
# accepted it; delivery_status stays "unknown" until a signed provider event
# (Api::V1::Integrations::EmailEventsController) says delivered, delayed,
# bounced or complained.
class EmployeeDocumentNotice < ApplicationRecord
  KINDS = %w[w2gu_available pay_stub_corrected].freeze
  STATUSES = %w[pending sent skipped failed].freeze
  DELIVERY_STATUSES = %w[unknown delivered delayed bounced complained].freeze
  SKIP_REASONS = %w[feature_off document_unavailable no_app_access email_not_verified recipient_not_allowed
    email_delivery_disabled email_not_configured].freeze
  # A later event never undoes a bounce or complaint.
  FINAL_DELIVERY_STATUSES = %w[bounced complained].freeze

  belongs_to :company
  belongs_to :employee_document
  belongs_to :employee
  belongs_to :paper_mailed_by, class_name: "User", optional: true

  def paper_follow_up_state(today: PayrollBusinessClock.today)
    return unless paper_due_on
    return "mailed" if paper_mailed_on

    paper_due_on < today ? "overdue" : "required"
  end

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :delivery_status, inclusion: { in: DELIVERY_STATUSES }
  validates :skip_reason, inclusion: { in: SKIP_REASONS }, allow_nil: true
end
