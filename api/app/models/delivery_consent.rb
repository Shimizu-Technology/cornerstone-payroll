# frozen_string_literal: true

class DeliveryConsent < ApplicationRecord
  KINDS = DeliveryDisclosure::KINDS
  METHODS = %w[employee_portal_checkbox employee_portal_pdf_verified].freeze
  DIGEST_PATTERN = DeliveryDisclosure::DIGEST_PATTERN

  belongs_to :company
  belongs_to :user
  belongs_to :employee
  belongs_to :employee_account_link
  belongs_to :delivery_disclosure
  belongs_to :withdrawn_by_user, class_name: "User", optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :disclosure_version, presence: true
  validates :disclosure_digest, presence: true, format: { with: DIGEST_PATTERN }
  validates :given_at, presence: true
  validates :method, presence: true, inclusion: { in: METHODS }
  validates :access_proof_verified_at, presence: true, if: :w2gu?
  validate :associations_match_company_and_employee
  validate :disclosure_snapshot_matches_record, on: :create
  validate :withdrawn_not_before_given

  scope :for_kind, ->(kind) { where(kind: kind.to_s) }
  scope :active, -> { where(withdrawn_at: nil) }
  scope :withdrawn, -> { where.not(withdrawn_at: nil) }
  scope :recent_first, -> { order(given_at: :desc, id: :desc) }

  def active?
    withdrawn_at.nil?
  end

  def withdrawn?
    withdrawn_at.present?
  end

  def w2gu?
    kind == "w2gu"
  end

  def pay_statements?
    kind == "pay_statements"
  end

  def matches_disclosure?(disclosure)
    disclosure.present? &&
      disclosure_version == disclosure.version &&
      disclosure_digest == disclosure.digest
  end

  private

  def associations_match_company_and_employee
    if employee && employee.company_id != company_id
      errors.add(:employee, "must belong to the consent company")
    end
    if employee_account_link && (employee_account_link.company_id != company_id || employee_account_link.employee_id != employee_id)
      errors.add(:employee_account_link, "must belong to the consent employee and company")
    end
  end

  def disclosure_snapshot_matches_record
    return unless delivery_disclosure

    errors.add(:kind, "must match the disclosure kind") if kind != delivery_disclosure.kind
    errors.add(:disclosure_version, "must match the disclosure version") if disclosure_version != delivery_disclosure.version
    errors.add(:disclosure_digest, "must match the disclosure digest") if disclosure_digest != delivery_disclosure.digest
  end

  def withdrawn_not_before_given
    return if withdrawn_at.blank? || given_at.blank?

    errors.add(:withdrawn_at, "cannot be earlier than given_at") if withdrawn_at < given_at
  end
end
