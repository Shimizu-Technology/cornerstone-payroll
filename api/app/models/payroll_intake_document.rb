# frozen_string_literal: true

class PayrollIntakeDocument < ApplicationRecord
  DOCUMENT_TYPES = %w[pasted_text image pdf other].freeze
  SOURCE_ROLES = %w[pasted_email email_attachment revel_hours supplemental_workbook supporting_document legacy_source].freeze
  VERIFICATION_STATUSES = %w[verified failed legacy_unverified].freeze
  IMMUTABLE_SOURCE_FIELDS = %w[
    payroll_intake_session_id document_type source_role position filename content_type
    storage_reference text_content byte_size sha256 payroll_submission_document_id
  ].freeze

  belongs_to :payroll_intake_session, inverse_of: :documents
  belongs_to :payroll_submission_document, optional: true

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }
  validates :source_role, inclusion: { in: SOURCE_ROLES }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validates :position,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            uniqueness: { scope: :payroll_intake_session_id }
  validates :storage_reference, uniqueness: true, allow_nil: true
  validate :portal_source_matches_package
  validate :has_content_or_reference
  validate :verified_source_has_fingerprint
  validate :source_identity_immutable, on: :update
  validate :package_accepts_source_document, on: :create

  delegate :company, :pay_period, to: :payroll_intake_session

  before_destroy :prevent_destroy, prepend: true
  after_destroy_commit :purge_stored_source

  scope :in_package_order, -> { order(:position, :id) }

  private

  def purge_stored_source
    return if storage_reference.blank?

    R2StorageService.new.delete(storage_reference)
  rescue StandardError => e
    Rails.logger.error("Payroll source document #{id} storage purge failed: #{e.class}: #{e.message}")
  end

  def portal_source_matches_package
    return unless payroll_submission_document

    source = payroll_submission_document
    period = source.submission.period
    return if source.company_id == company.id && period.start_date == pay_period.start_date && period.end_date == pay_period.end_date && source.sha256 == sha256

    errors.add(:payroll_submission_document, "must match this package's company, period and fingerprint")
  end

  def has_content_or_reference
    return if text_content.present? || extracted_text.present? || storage_reference.present? || filename.present?

    errors.add(:base, "document must include text, an extracted value, or a file reference")
  end

  def verified_source_has_fingerprint
    return unless verification_status == "verified"

    errors.add(:byte_size, "must be greater than zero") unless byte_size.to_i.positive?
    errors.add(:sha256, "must be a SHA-256 fingerprint") unless sha256.to_s.match?(/\A[0-9a-f]{64}\z/)
    errors.add(:verified_at, "must be recorded") if verified_at.blank?
  end

  def source_identity_immutable
    changed = changes_to_save.keys & IMMUTABLE_SOURCE_FIELDS
    return if changed.empty?

    errors.add(:base, "Payroll source document evidence cannot be changed")
  end

  def package_accepts_source_document
    return if payroll_intake_session.blank? || payroll_intake_session.status == "draft"

    errors.add(:base, "Sources cannot be added after the payroll package is previewed")
  end

  def prevent_destroy
    session = payroll_intake_session
    return if destroyed_by_association&.active_record == PayrollIntakeSession &&
      session.destroyed_by_association&.active_record == PayPeriod && session.pay_period.deletable_unapproved_run?

    errors.add(:base, "Payroll source documents can only be removed when deleting their unapproved payroll run")
    throw(:abort)
  end
end
