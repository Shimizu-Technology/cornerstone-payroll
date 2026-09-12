# frozen_string_literal: true

class PayrollIntakeSession < ApplicationRecord
  PACKAGE_SCHEMA_VERSION = "1.0"
  IMMUTABLE_SOURCE_FIELDS = %w[
    company_id pay_period_id source_type source_label import_hash parser_version
    package_id package_revision package_schema_version
  ].freeze
  SOURCE_TYPES = %w[spike_email mosa_revel].freeze
  STATUSES = %w[draft previewed reviewed applied failed].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true

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
  validate :source_identity_immutable, on: :update

  before_destroy :prevent_destroy, prepend: true

  scope :for_pay_period, ->(pay_period_id) { where(pay_period_id: pay_period_id) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :in_revision_order, -> { order(:package_revision, :id) }

  def previewable?
    status.in?(%w[draft failed])
  end

  def applyable?
    status.in?(%w[previewed reviewed])
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
end
