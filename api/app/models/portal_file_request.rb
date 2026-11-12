# frozen_string_literal: true

# Cornerstone asks a client for one specific file, optionally for an employee
# and/or a pay period. The client answers by uploading in the request; staff
# accept the answer or ask again. Every step is a typed message in the
# request's conversation, so both sides see the same history.
class PortalFileRequest < ApplicationRecord
  include PortalInboxUpdates

  STATUSES = %w[requested responded accepted withdrawn].freeze
  OPEN_STATUSES = %w[requested responded].freeze
  STATUS_LABELS = {
    "requested" => "Waiting for the file",
    "responded" => "File sent, waiting for Cornerstone",
    "accepted" => "Accepted",
    "withdrawn" => "No longer needed"
  }.freeze

  belongs_to :company
  belongs_to :client_portal_thread
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :responded_by, class_name: "User", optional: true
  belongs_to :resolved_by, class_name: "User", optional: true
  belongs_to :employee, optional: true
  belongs_to :payroll_submission_period, optional: true
  belongs_to :request_message, class_name: "ClientPortalMessage", optional: true
  belongs_to :last_response_message, class_name: "ClientPortalMessage", optional: true
  has_many :messages, class_name: "ClientPortalMessage", foreign_key: :portal_file_request_id, inverse_of: :file_request,
    dependent: :restrict_with_error

  validates :title, presence: true, length: { maximum: 200 }
  validates :category, inclusion: { in: ClientDocument::CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :idempotency_key, length: { maximum: 128 }, allow_nil: true
  validate :related_records_share_company

  scope :outstanding, -> { where(status: OPEN_STATUSES) }

  def outstanding?
    OPEN_STATUSES.include?(status)
  end

  def status_label
    STATUS_LABELS.fetch(status)
  end

  private

  def related_records_share_company
    { client_portal_thread: client_portal_thread, employee: employee, payroll_submission_period: payroll_submission_period }.each do |name, record|
      errors.add(name, "must belong to the same company") if record && record.company_id != company_id
    end
  end
end
