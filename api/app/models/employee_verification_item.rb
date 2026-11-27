# frozen_string_literal: true

class EmployeeVerificationItem < ApplicationRecord
  EVENT_KINDS = %w[
    new_hire
    compensation_change
    w4_change
    payment_method_change
    identity_tax_change
    contractor_tax_change
    termination
    rehire
    profile_change
  ].freeze

  STATUSES = %w[pending_verification returned_to_client verified superseded].freeze
  OPEN_STATUSES = %w[pending_verification returned_to_client].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :source_actor, class_name: "User", optional: true
  belongs_to :verified_by, class_name: "User", optional: true
  belongs_to :returned_by, class_name: "User", optional: true
  belongs_to :superseded_by, class_name: "EmployeeVerificationItem", optional: true
  belongs_to :source_record, polymorphic: true, optional: true

  has_many :pay_period_verification_acknowledgements, dependent: :restrict_with_error

  validates :event_kind, inclusion: { in: EVENT_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :affects_pay, :fixed_by_staff, inclusion: { in: [ true, false ] }
  validate :company_matches_employee
  validate :company_matches_superseded_by
  validate :cannot_supersede_self
  validate :cannot_supersede_acknowledged_item

  scope :open_items, -> { where(status: OPEN_STATUSES) }
  scope :pending_verification, -> { where(status: "pending_verification") }
  scope :returned_to_client, -> { where(status: "returned_to_client") }
  scope :affecting_pay, -> { where(affects_pay: true) }

  def open?
    OPEN_STATUSES.include?(status)
  end

  def acknowledged_in_committed_run?
    if association(:pay_period_verification_acknowledgements).loaded?
      pay_period_verification_acknowledgements.any?
    else
      pay_period_verification_acknowledgements.exists?
    end
  end

  private

  def company_matches_employee
    return if employee.blank? || company_id == employee.company_id

    errors.add(:company, "must match the employee's company")
  end

  def company_matches_superseded_by
    return if superseded_by.blank? || company_id == superseded_by.company_id

    errors.add(:superseded_by, "must belong to the same company")
  end

  def cannot_supersede_self
    return if superseded_by_id.blank? || id.blank? || superseded_by_id != id

    errors.add(:superseded_by, "cannot reference the same verification item")
  end

  def cannot_supersede_acknowledged_item
    return unless persisted? && status == "superseded" && will_save_change_to_status?
    return unless pay_period_verification_acknowledgements.exists?

    errors.add(:status, "cannot be superseded after being acknowledged in a committed pay run")
  end
end
