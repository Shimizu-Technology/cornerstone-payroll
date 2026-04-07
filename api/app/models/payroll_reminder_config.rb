# frozen_string_literal: true

class PayrollReminderConfig < ApplicationRecord
  belongs_to :company

  validates :days_before_due, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 14 }
  validates :recipients, presence: true, if: :enabled?
  validate :recipients_must_be_valid_emails

  private

  def recipients_must_be_valid_emails
    return if recipients.blank?

    recipients.each do |email|
      unless email.is_a?(String) && email.match?(URI::MailTo::EMAIL_REGEXP)
        errors.add(:recipients, "contains invalid email: #{email}")
      end
    end
  end
end
