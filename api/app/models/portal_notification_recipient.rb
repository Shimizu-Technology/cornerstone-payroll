# frozen_string_literal: true

# A person who receives one client's staff-side portal alerts: either an app
# user or an extra address for someone without an account. Extra addresses get
# the same generic email; its link still requires a normal sign-in.
class PortalNotificationRecipient < ApplicationRecord
  MAX_EXTRA_EMAILS = 20

  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :added_by, class_name: "User", optional: true

  before_validation { self.email = self.class.normalize_email(email) if email }

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  validates :user_id, uniqueness: { scope: :company_id }, allow_nil: true
  validates :email, uniqueness: { scope: :company_id }, allow_nil: true
  validate :exactly_one_target

  scope :users, -> { where.not(user_id: nil) }
  scope :extra_emails, -> { where.not(email: nil) }

  def self.normalize_email(value)
    value.to_s.strip.downcase.presence
  end

  def self.valid_email?(value)
    value.to_s.match?(URI::MailTo::EMAIL_REGEXP) && value.to_s.length <= 254
  end

  private

  def exactly_one_target
    errors.add(:base, "Choose a user or an email address") unless user_id.nil? ^ email.nil?
  end
end
