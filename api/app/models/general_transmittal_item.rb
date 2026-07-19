# frozen_string_literal: true

class GeneralTransmittalItem < ApplicationRecord
  ITEM_TYPES = %w[check payment document report tax_obligation manual other].freeze

  belongs_to :general_transmittal, inverse_of: :items

  before_validation :normalize_details
  before_validation :default_title

  validates :item_type, presence: true, inclusion: { in: ITEM_TYPES }
  validates :title, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :source_key,
    uniqueness: { scope: :general_transmittal_id },
    allow_nil: true
  validates :source_id,
    uniqueness: {
      scope: [ :general_transmittal_id, :source_type ],
      message: "has already been added to this transmittal"
    },
    if: :source_reference?

  def self.from_non_employee_check(check, position:)
    new(
      source_type: "NonEmployeeCheck",
      source_id: check.id,
      item_type: "check",
      title: check_title(check),
      payable_to: check.payable_to,
      check_number: check.check_number,
      amount: check.amount,
      details: check_details(check),
      position: position
    )
  end

  def linked_non_employee_check?
    source_type == "NonEmployeeCheck" && source_id.present?
  end

  def calculated_obligation?
    item_type == "tax_obligation"
  end

  private_class_method def self.check_title(check)
    label = check.check_type.to_s.titleize
    label = "Check" if label.blank?
    "Check for #{check.payable_to} (#{label})"
  end

  private_class_method def self.check_details(check)
    details = []
    details << "For: #{check.memo}" if check.memo.present?
    details << "Description: #{check.description}" if check.description.present?
    details << "Reference: #{check.reference_number}" if check.reference_number.present?
    details << "Confirmation: #{check.confirmation_number}" if check.confirmation_number.present?
    details << "Payment date: #{check.effective_payment_date.strftime('%m/%d/%Y')}" if check.effective_payment_date
    details
  end

  private

  def normalize_details
    self.details = Array(details).map(&:to_s).map(&:strip).reject(&:blank?)
  end

  def default_title
    self.title = "Transmittal item" if title.blank?
  end

  def source_reference?
    source_type.present? && source_id.present?
  end
end
