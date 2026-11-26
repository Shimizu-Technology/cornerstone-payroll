# frozen_string_literal: true

class PayrollReviewPackage < ApplicationRecord
  include PortalInboxUpdates

  APPROVAL_ACKNOWLEDGEMENT = "I approve this exact payroll review revision for processing."
  STATUSES = %w[pending approved superseded].freeze
  OVERRIDE_ACKNOWLEDGEMENT = "I am approving this exact payroll revision for the client under Cornerstone authority."
  OVERRIDE_REASON_LENGTH = (10..500).freeze
  APPROVAL_METHODS = %w[client_portal email_attestation cornerstone_override].freeze
  IMMUTABLE_REVISION_FIELDS = %w[
    company_id pay_period_id revision schema_version calculation_checksum calculation_snapshot
    source_manifest generated_by_id generated_at
  ].freeze
  APPROVAL_EVIDENCE_FIELDS = %w[
    approved_at approved_by_id approval_recorded_by_id approval_method approval_acknowledgement
    approval_notes approval_evidence_reference override_reason self_override
  ].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :generated_by, class_name: "User", optional: true
  belongs_to :changes_requested_by, class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :approval_recorded_by, class_name: "User", optional: true

  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :schema_version, :calculation_checksum, :generated_at, presence: true
  validates :calculation_checksum, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :approval_method, inclusion: { in: APPROVAL_METHODS }, allow_nil: true
  validates :change_request_note, length: { maximum: 2_000 }, allow_blank: true
  validate :change_request_evidence
  validates :approval_notes, length: { maximum: 2_000 }, allow_blank: true
  validates :approval_evidence_reference, length: { maximum: 500 }, allow_blank: true
  validate :company_matches_pay_period
  validates :override_reason, length: { in: OVERRIDE_REASON_LENGTH }, if: :cornerstone_override?
  validates :override_reason, absence: true, unless: :cornerstone_override?
  validates :self_override, exclusion: { in: [ true ] }, unless: :cornerstone_override?
  validate :approval_shape
  validate :supersession_shape
  validate :revision_identity_immutable, on: :update
  validate :approval_evidence_immutable, on: :update
  validate :status_transition_allowed, on: :update
  validate :shared_review_history_immutable, on: :update

  scope :current, -> { where(superseded_at: nil) }
  scope :summary, -> { select(column_names - [ "calculation_snapshot" ]) }
  scope :shared_history, -> { where.not(sent_for_client_approval_at: nil).or(where.not(changes_requested_at: nil)) }

  def cornerstone_override?
    approval_method == "cornerstone_override"
  end

  def approved?
    status == "approved"
  end

  def pending?
    status == "pending"
  end

  def superseded?
    status == "superseded"
  end

  # New automatic revisions can be discarded. Shared, client-authored and
  # unverified legacy evidence must be retained.
  def retained_client_evidence?
    client_review_history_unknown? || sent_for_client_approval_at.present? || changes_requested_at.present? || approved? ||
      APPROVAL_EVIDENCE_FIELDS.any? { |field| self[field].present? }
  end

  before_destroy :preserve_client_evidence

  private

  def change_request_evidence
    if changes_requested_at && (change_request_note.to_s.strip.blank? || changes_requested_by_id.nil?)
      errors.add(:base, "Change requests require a client, time and note")
    end
    if changes_requested_at_in_database && (changes_to_save.keys & %w[changes_requested_at changes_requested_by_id change_request_note]).any?
      errors.add(:base, "Change request evidence cannot be changed")
    end
  end

  def shared_review_history_immutable
    if published_at_in_database && will_save_change_to_published_at?
      errors.add(:published_at, "cannot change after publication")
    end
    return unless sent_for_client_approval_at_in_database.present? && will_save_change_to_sent_for_client_approval_at?

    errors.add(:sent_for_client_approval_at, "cannot change after the review was shared")
  end

  def preserve_client_evidence
    return unless retained_client_evidence?

    errors.add(:base, "This client review was shared or has a client decision or comment and must be kept.")
    throw :abort
  end


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
      expected_acknowledgement = cornerstone_override? ? OVERRIDE_ACKNOWLEDGEMENT : APPROVAL_ACKNOWLEDGEMENT
      unless approval_acknowledgement == expected_acknowledgement
        errors.add(:approval_acknowledgement, "must confirm the exact payroll revision")
      end
      if approval_method == "email_attestation" && approval_evidence_reference.to_s.strip.blank?
        errors.add(:approval_evidence_reference, "is required for an email attestation")
      end
      if (approval_method == "client_portal" || cornerstone_override?) && approved_by_id != approval_recorded_by_id
        errors.add(:approval_recorded_by, cornerstone_override? ? "must be the overriding admin" : "must be the approving client portal user")
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
