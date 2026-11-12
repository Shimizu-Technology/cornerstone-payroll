# frozen_string_literal: true

# One pay period's exchange between a client and Cornerstone: the client's
# numbered submissions, staff drafts for review, the period conversation and a
# status both sides see. It is evidence for staff to apply by hand. Nothing
# here changes payroll, pay runs or employee records.
class PayrollSubmissionPeriod < ApplicationRecord
  include PortalInboxUpdates

  STATUSES = %w[waiting_for_files submitted received in_review draft_ready approved changes_requested paid].freeze
  STATUS_LABELS = {
    "waiting_for_files" => "Waiting for files",
    "submitted" => "Sent to Cornerstone",
    "received" => "Received",
    "in_review" => "In review",
    "draft_ready" => "Draft ready",
    "approved" => "Approved",
    "changes_requested" => "Changes requested",
    "paid" => "Paid"
  }.freeze

  # Who may move the period, from where, to where. Clients and staff each
  # have their own events; neither can reach the other's.
  EVENTS = {
    "submit" => { audience: "client", from: STATUSES - %w[paid], to: "submitted" },
    "approve" => { audience: "client", from: %w[draft_ready], to: "approved" },
    "request_changes" => { audience: "client", from: %w[draft_ready], to: "changes_requested" },
    "acknowledge" => { audience: "staff", from: %w[submitted], to: "received" },
    # Source evidence records what staff did, independently of client draft
    # approval/payment. Importing or dispositioning does not change that status.
    "import" => { audience: "staff", from: STATUSES, to: :unchanged },
    "resolve_source" => { audience: "staff", from: STATUSES, to: :unchanged },
    "start_review" => { audience: "staff", from: %w[received changes_requested], to: "in_review" },
    "post_draft" => { audience: "staff", from: %w[waiting_for_files received in_review draft_ready changes_requested approved], to: "draft_ready" },
    "mark_paid" => { audience: "staff", from: %w[draft_ready approved], to: "paid" }
  }.freeze

  class TransitionError < StandardError; end

  belongs_to :company
  belongs_to :pay_period, optional: true
  belongs_to :company_pay_schedule, optional: true
  belongs_to :status_changed_by, class_name: "User", optional: true
  belongs_to :client_portal_thread, optional: true
  has_many :submissions, -> { order(revision: :desc) }, class_name: "PayrollSubmission", inverse_of: :period, dependent: :restrict_with_error
  has_many :drafts, -> { order(revision: :desc) }, class_name: "PayrollSubmissionDraft", inverse_of: :period, dependent: :restrict_with_error
  has_many :status_events, -> { order(:id) }, class_name: "PayrollSubmissionStatusEvent", inverse_of: :period, dependent: :restrict_with_error
  has_many :read_receipts, class_name: "PayrollSubmissionPeriodReadReceipt", dependent: :delete_all
  has_many :file_requests, class_name: "PortalFileRequest", dependent: :restrict_with_error

  # A requested file that is still missing, or sent but not yet accepted,
  # keeps the period from being marked complete.
  def outstanding_file_requests
    file_requests.outstanding
  end

  validates :start_date, :end_date, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: %w[pay_period schedule] }
  validate :end_after_start
  validate :related_records_share_company

  def self.ref_for(start_date, end_date)
    "#{start_date.iso8601}_#{end_date.iso8601}"
  end

  def ref
    persisted? ? id.to_s : self.class.ref_for(start_date, end_date)
  end

  def label
    PayrollSubmissions::PeriodLabel.call(start_date, end_date)
  end

  def status_label
    STATUS_LABELS.fetch(status)
  end

  def current_submission
    submissions.first
  end

  def pending_source_review?
    source = submissions.first
    return false unless source
    return false if PayrollSubmissionImport.where(current_submission_id: source.id).where.not(applied_at: nil).exists?

    !status_events.exists?(event: "resolve_source", payroll_submission_id: source.id)
  end

  def current_draft
    drafts.where.not(posted_at: nil).first
  end

  def can?(event, audience)
    rule = EVENTS[event.to_s]
    rule.present? && rule[:audience] == audience && rule[:from].include?(status)
  end

  # Call inside the caller's transaction with the period row locked.
  def transition!(event, actor:, submission: nil, draft: nil, note: nil)
    audience = self.class.audience_for(actor)
    rule = EVENTS[event.to_s]
    raise TransitionError, "That action is not available" unless rule && audience
    raise TransitionError, "Only #{rule[:audience] == 'staff' ? 'Cornerstone staff' : 'the client'} can do that" unless rule[:audience] == audience
    unless rule[:from].include?(status)
      raise TransitionError, "This period is #{status_label.downcase}, so that action is not available"
    end

    from = status
    target = rule[:to] == :unchanged ? status : rule[:to]
    update!(status: target, status_changed_at: Time.current, status_changed_by: actor) unless rule[:to] == :unchanged
    status_events.create!(
      company_id: company_id, event: event.to_s, from_status: from, to_status: target,
      actor: actor, actor_audience: audience, actor_name_snapshot: actor.name,
      payroll_submission: submission, payroll_submission_draft: draft, note: note.presence
    )
  end

  def self.audience_for(user)
    if user&.client? then "client"
    elsif user&.staff_member? then "staff"
    end
  end

  # Staff mark a period seen only through the latest client event they were
  # shown. The cursor never moves backwards, and a client event that arrives
  # after the page was displayed stays unread.
  def mark_seen_through!(user, event_id:)
    event_id = Integer(event_id.to_s, 10)
    unless event_id.zero? || status_events.exists?(id: event_id, actor_audience: "client")
      raise ActiveRecord::RecordNotFound, "That update is not part of this period"
    end

    with_lock do
      receipt = read_receipts.find_or_initialize_by(user_id: user.id)
      return receipt if receipt.persisted? && receipt.last_seen_event_id >= event_id

      receipt.update!(last_seen_event_id: event_id, seen_at: Time.current)
      receipt
    end
  end

  def latest_client_event
    status_events.where(actor_audience: "client").reorder(id: :desc).first
  end

  private

  def end_after_start
    return if start_date.blank? || end_date.blank? || end_date >= start_date

    errors.add(:end_date, "must be on or after the start date")
  end

  def related_records_share_company
    { pay_period: pay_period, company_pay_schedule: company_pay_schedule, client_portal_thread: client_portal_thread }.each do |name, record|
      errors.add(name, "must belong to the same company") if record && record.company_id != company_id
    end
  end
end
