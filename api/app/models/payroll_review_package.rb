# frozen_string_literal: true

class PayrollReviewPackage < ApplicationRecord
  APPROVAL_ACKNOWLEDGEMENT = "I approve this exact payroll review revision for processing."
  STATUSES = %w[pending approved superseded].freeze
  APPROVAL_METHODS = %w[client_portal email_attestation].freeze
  IMMUTABLE_REVISION_FIELDS = %w[
    company_id pay_period_id revision schema_version calculation_checksum calculation_snapshot
    source_manifest generated_by_id generated_at
  ].freeze
  APPROVAL_EVIDENCE_FIELDS = %w[
    approved_at approved_by_id approval_recorded_by_id approval_method approval_acknowledgement
    approval_notes approval_evidence_reference
  ].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :generated_by, class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :approval_recorded_by, class_name: "User", optional: true

  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :schema_version, :calculation_checksum, :generated_at, presence: true
  validates :calculation_checksum, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :approval_method, inclusion: { in: APPROVAL_METHODS }, allow_nil: true
  validates :approval_notes, length: { maximum: 2_000 }, allow_blank: true
  validates :approval_evidence_reference, length: { maximum: 500 }, allow_blank: true
  validate :company_matches_pay_period
  validate :approval_shape
  validate :supersession_shape
  validate :revision_identity_immutable, on: :update
  validate :approval_evidence_immutable, on: :update
  validate :status_transition_allowed, on: :update

  scope :current, -> { where(superseded_at: nil) }

  def approved?
    status == "approved"
  end

  def pending?
    status == "pending"
  end

  def superseded?
    status == "superseded"
  end

  private

  def company_matches_pay_period
    return if company_id.blank? || pay_period.blank? || company_id == pay_period.company_id

    errors.add(:company, "must match the pay period company")
  end

  def approval_shape
    if approved?
      errors.add(:approved_at, "is required") if approved_at.blank?
      errors.add(:approved_by, "is required") if approved_by.blank?
      errors.add(:approval_recorded_by, "is required") if approval_recorded_by.blank?
      errors.add(:approval_method, "is required") if approval_method.blank?
      unless approval_acknowledgement == APPROVAL_ACKNOWLEDGEMENT
        errors.add(:approval_acknowledgement, "must confirm the exact payroll revision")
      end
      if approval_method == "email_attestation" && approval_evidence_reference.to_s.strip.blank?
        errors.add(:approval_evidence_reference, "is required for an email attestation")
      end
      if approval_method == "client_portal" && approved_by_id != approval_recorded_by_id
        errors.add(:approval_recorded_by, "must be the approving client portal user")
      end
    elsif pending? && (approved_at.present? || approved_by.present? || approval_recorded_by.present? || approval_method.present? || approval_acknowledgement.present?)
      errors.add(:base, "approval evidence is only valid for an approved review package")
    end
  end

  def supersession_shape
    if superseded?
      errors.add(:superseded_at, "is required") if superseded_at.blank?
      errors.add(:supersession_reason, "is required") if supersession_reason.to_s.strip.blank?
    elsif superseded_at.present? || supersession_reason.present?
      errors.add(:base, "supersession evidence is only valid for a superseded review package")
    end
  end

  def revision_identity_immutable
    changed = changes_to_save.keys & IMMUTABLE_REVISION_FIELDS
    errors.add(:base, "payroll review revision identity cannot be changed") if changed.any?
  end

  def approval_evidence_immutable
    return unless status_in_database.in?(%w[approved superseded]) && approval_method_in_database.present?

    changed = changes_to_save.keys & APPROVAL_EVIDENCE_FIELDS
    errors.add(:base, "payroll review approval evidence cannot be changed") if changed.any?
  end

  def status_transition_allowed
    from = status_in_database
    allowed = {
      "pending" => %w[pending approved superseded],
      "approved" => %w[approved superseded],
      "superseded" => %w[superseded]
    }.fetch(from, [])
    errors.add(:status, "cannot transition from #{from}") unless status.in?(allowed)
  end
end
