# frozen_string_literal: true

class PayrollIntakeSession < ApplicationRecord
  PACKAGE_SCHEMA_VERSION = "1.0"
  IMMUTABLE_SOURCE_FIELDS = %w[
    company_id pay_period_id source_type source_label import_hash parser_version
    package_id package_revision package_schema_version supersedes_id supersession_reason
  ].freeze
  SOURCE_TYPES = %w[spike_email mosa_revel].freeze
  STATUSES = %w[draft previewed reviewed applied failed].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true
  belongs_to :supersedes,
             class_name: "PayrollIntakeSession",
             optional: true,
             inverse_of: :replacement_session
  belongs_to :superseded_by_user, class_name: "User", optional: true

  has_one :replacement_session,
          class_name: "PayrollIntakeSession",
          foreign_key: :supersedes_id,
          inverse_of: :supersedes,
          dependent: :restrict_with_error

  has_many :documents,
           class_name: "PayrollIntakeDocument",
           dependent: :destroy,
           inverse_of: :payroll_intake_session
  has_many :rows,
           -> { order(:position, :id) },
           class_name: "PayrollIntakeRow",
           dependent: :destroy,
           inverse_of: :payroll_intake_session

  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :import_hash, presence: true
  validates :parser_version, presence: true
  validates :package_id, presence: true, uniqueness: true
  validates :package_revision,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :pay_period_id }
  validates :package_schema_version, presence: true
  validate :company_matches_pay_period
  validate :superseded_package_matches_source, on: :create
  validate :supersession_reason_present, on: :create
  validate :source_identity_immutable, on: :update

  before_destroy :prevent_destroy, prepend: true

  scope :for_pay_period, ->(pay_period_id) { where(pay_period_id: pay_period_id) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :in_revision_order, -> { order(:package_revision, :id) }
  scope :current, -> { where(superseded_at: nil) }

  def previewable?
    status.in?(%w[draft failed])
  end

  def applyable?
    current? && status.in?(%w[previewed reviewed])
  end

  def current?
    superseded_at.blank?
  end

  def superseded?
    superseded_at.present?
  end

  def mark_previewed!(warnings: [], totals: {})
    update!(status: "previewed", warnings: warnings, totals: totals, error_message: nil)
  end

  def mark_failed!(message)
    update!(status: "failed", error_message: message.to_s.truncate(2000))
  end

  def mark_reviewed!(actor: nil)
    update!(status: "reviewed", reviewed_by: actor, reviewed_at: Time.current)
  end

  def mark_applied!(actor: nil)
    update!(status: "applied", applied_by: actor, applied_at: Time.current)
  end

  def mark_superseded!(actor: nil, at: Time.current)
    update!(superseded_at: at, superseded_by_user: actor)
  end

  private

  def source_identity_immutable
    changed = changes_to_save.keys & IMMUTABLE_SOURCE_FIELDS
    return if changed.empty?

    errors.add(:base, "Payroll source package identity cannot be changed")
  end

  def prevent_destroy
    errors.add(:base, "Payroll source packages cannot be deleted")
    throw(:abort)
  end

  def company_matches_pay_period
    return if pay_period.blank? || company_id.blank?
    return if pay_period.company_id == company_id

    errors.add(:company_id, "must match the pay period company")
  end

  def superseded_package_matches_source
    return if supersedes.blank?
    return if supersedes.company_id == company_id &&
      supersedes.pay_period_id == pay_period_id &&
      supersedes.source_type == source_type &&
      supersedes.package_revision < package_revision.to_i &&
      supersedes.superseded?

    errors.add(:supersedes, "must be the newly superseded earlier package for this pay period and source")
  end

  def supersession_reason_present
    return if supersedes.blank? && supersession_reason.blank?
    return if supersedes.present? && supersession_reason.to_s.strip.present?

    errors.add(:supersession_reason, "is required when replacing a payroll source package")
  end
end
