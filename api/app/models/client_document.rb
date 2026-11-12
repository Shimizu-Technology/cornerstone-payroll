# frozen_string_literal: true

class ClientDocument < ApplicationRecord
  include PortalInboxUpdates
  MAX_FILE_SIZE = 25.megabytes
  CATEGORIES = %w[
    payroll_source
    payroll_review
    employee_onboarding
    tax_notice
    filing_evidence
    direct_deposit
    identity
    insurance
    misc
  ].freeze
  ALLOWED_EXTENSIONS = %w[pdf png jpg jpeg webp txt csv doc docx xls xlsx].freeze
  ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    application/msword
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    image/jpeg
    image/png
    image/webp
    text/plain
    text/csv
  ].freeze
  ORIGINAL_INLINE_PREVIEW_EXTENSIONS = %w[pdf png jpg jpeg webp].freeze
  GENERATED_PREVIEW_EXTENSIONS = %w[doc docx xls xlsx csv txt].freeze
  SCAN_STATUSES = %w[not_scanned pending clean infected error].freeze
  PREVIEW_STATUSES = %w[pending processing ready failed not_required].freeze

  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :read_receipts, class_name: "PortalDocumentReadReceipt", dependent: :delete_all
  belongs_to :archived_by, class_name: "User", optional: true
  belongs_to :company
  belongs_to :employee, optional: true
  belongs_to :uploaded_by, class_name: "User", optional: true
  has_many :client_portal_messages, dependent: :restrict_with_error
  has_many :portal_message_attachments, dependent: :restrict_with_error
  has_many :employee_document_requirements, dependent: :restrict_with_error
  has_many :employee_document_requirement_events, dependent: :restrict_with_error
  has_many :payroll_filing_events, foreign_key: :evidence_document_id, dependent: :restrict_with_error
  has_many :payroll_submission_documents, dependent: :restrict_with_error

  validates :title, :category, :file_name, :file_key, :content_type, presence: true
  validates :uploaded_by, presence: true, on: :create
  validates :category, inclusion: { in: CATEGORIES }
  validates :file_size, numericality: { greater_than: 0 }
  validates :scan_status, inclusion: { in: SCAN_STATUSES }
  validates :preview_status, inclusion: { in: PREVIEW_STATUSES }

  before_destroy :protect_retained_evidence, prepend: true
  after_create_commit :enqueue_scan

  scope :active, -> { where(archived_at: nil) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :client_visible, -> { where(visible_to_client: true) }
  # Files a person may attach to a message: shared with the client, not
  # archived and not held back by the safety check.
  scope :attachable, -> { active.client_visible.where.not(scan_status: ClientDocumentScanner::BLOCKED_STATUSES) }

  def self.detected_content_type(file)
    ClientDocumentFileValidator.new(file).validate!
  end

  def self.upload_validation_errors(file)
    return [ "is required" ] unless file.present?

    ClientDocumentFileValidator.new(file).validate!
    []
  rescue ClientDocumentFileValidator::InvalidFile => e
    [ e.message ]
  end

  def archived?
    archived_at.present?
  end

  def retained_evidence?
    archived? || client_portal_messages.exists? || portal_message_attachments.exists? || employee_document_requirements.exists? ||
      employee_document_requirement_events.exists? || payroll_filing_events.exists? ||
      payroll_submission_documents.exists? || payroll_submission_draft?
  end

  # Raised instead of archiving a file the client still needs for review.
  class SharedForReview < StandardError; end

  def payroll_submission_draft?
    payroll_drafts_using_file.exists?
  end

  # A posted draft is what the client approves. Archiving would hide it from
  # them while the period still shows it, so posted draft files stay usable.
  def posted_payroll_draft?
    payroll_drafts_using_file.posted.exists?
  end

  def ensure_usable_for!(purpose, staff_read: false)
    if archived? && !(staff_read && %i[download preview].include?(purpose))
      raise ClientDocumentScanner::Blocked, "This file has been archived. Contact Cornerstone if you need it."
    end

    ClientDocumentScanner.ensure_allowed!(self, purpose: purpose)
  end

  def archive_or_destroy!(actor:)
    with_lock do
      if posted_payroll_draft?
        raise SharedForReview, "This file is part of a draft shared with the client for review. Post a corrected draft instead of removing it."
      end

      if retained_evidence?
        update!(archived_at: Time.current, archived_by: actor) unless archived?
        :archived
      else
        destroy!
        :deleted
      end
    end
  end

  def download_filename
    name = file_name.to_s.tr("\\", "/").split("/").last.to_s
    name = name.gsub(/[[:cntrl:]\u202A-\u202E\u2066-\u2069]/, "").strip
    name.presence || "document.bin"
  end

  def preview_ready?
    preview_status == "ready" && preview_file_key.present?
  end

  def preview_generation_required?
    GENERATED_PREVIEW_EXTENSIONS.include?(file_extension)
  end

  def preview_served_from_original?
    ORIGINAL_INLINE_PREVIEW_EXTENSIONS.include?(file_extension)
  end

  def preview_available?(staff_read: false)
    (staff_read || !archived?) && (preview_ready? || preview_served_from_original?)
  end

  def preview_filename
    return download_filename if preview_served_from_original?

    "#{File.basename(download_filename, ".*")}-preview.pdf"
  end

  def file_extension
    File.extname(file_name.to_s).delete(".").downcase
  end

  def self.initial_preview_status_for(file)
    extension = File.extname(file.original_filename.to_s).delete(".").downcase
    return "not_required" if ORIGINAL_INLINE_PREVIEW_EXTENSIONS.include?(extension)
    return "pending" if GENERATED_PREVIEW_EXTENSIONS.include?(extension)

    "failed"
  end
  private

  def payroll_drafts_using_file
    PayrollSubmissionDraft.where(company_id: company_id).where("paycheck_document_id = :id OR direct_deposit_document_id = :id", id: id)
  end

  def protect_retained_evidence
    return unless retained_evidence?

    errors.add(:base, "This file is retained evidence. Archive it instead of deleting it.")
    throw :abort
  end

  def enqueue_scan
    ScanClientDocumentJob.perform_later(id) if scan_status == "pending"
  rescue StandardError => e
    # The upload transaction has committed. Keep the original and pending
    # state for scanner recovery; never let enqueue failure trigger blob cleanup.
    Rails.logger.error("Client document scan enqueue failed for #{id}: #{e.class}")
  end
end
