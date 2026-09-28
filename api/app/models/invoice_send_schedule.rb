# frozen_string_literal: true

class InvoiceSendSchedule < ApplicationRecord
  STATUSES = %w[pending sending sent failed cancelled].freeze

  belongs_to :organization
  belongs_to :invoice
  belongs_to :created_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :send_at, presence: true
  validate :invoice_belongs_to_organization
  validate :recipients_are_valid

  scope :due, ->(at = Time.current) { where(status: "pending").where("send_at <= ?", at) }

  def self.normalize_recipients(values)
    Array(values).flat_map { |value| value.to_s.split(/[;,]/) }.map(&:strip).reject(&:blank?).uniq
  end

  private

  def invoice_belongs_to_organization
    return if invoice.blank? || organization.blank? || invoice.organization_id == organization_id

    errors.add(:invoice, "must belong to the same organization")
  end

  def recipients_are_valid
    if recipients.blank? || recipients.size > 10 || recipients.any? { |email| email !~ URI::MailTo::EMAIL_REGEXP }
      errors.add(:recipients, "must contain 1 to 10 valid email addresses")
    end
  end
end
