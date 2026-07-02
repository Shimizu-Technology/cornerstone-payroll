# frozen_string_literal: true

class PayrollIntakeDocument < ApplicationRecord
  DOCUMENT_TYPES = %w[pasted_text image pdf other].freeze

  belongs_to :payroll_intake_session, inverse_of: :documents

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }
  validate :has_content_or_reference

  delegate :company, :pay_period, to: :payroll_intake_session

  private

  def has_content_or_reference
    return if text_content.present? || extracted_text.present? || storage_reference.present? || filename.present?

    errors.add(:base, "document must include text, an extracted value, or a file reference")
  end
end
