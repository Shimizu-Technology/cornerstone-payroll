# frozen_string_literal: true

# A member of one client's Cornerstone account team (staff-side portal alert
# recipients): either an app user (optionally designated as lead or backup) or
# an extra address for someone without an account. Extra addresses get the same
# alert email; its link still requires a normal sign-in.
class PortalNotificationRecipient < ApplicationRecord
  MAX_EXTRA_EMAILS = 20
  TEAM_ROLES = %w[lead backup].freeze

  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :added_by, class_name: "User", optional: true

  before_validation { self.email = self.class.normalize_email(email) if email }
  before_validation { self.team_role = team_role.to_s.strip.downcase.presence }

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  validates :user_id, uniqueness: { scope: :company_id }, allow_nil: true
  validates :email, uniqueness: { scope: :company_id }, allow_nil: true
  validates :team_role, inclusion: { in: TEAM_ROLES }, allow_nil: true
  validates :team_role, uniqueness: { scope: :company_id }, if: -> { team_role.present? }
  validate :exactly_one_target
  validate :team_role_requires_user

  scope :users, -> { where.not(user_id: nil) }
  scope :extra_emails, -> { where.not(email: nil) }
  scope :lead, -> { where(team_role: "lead") }
  scope :backup, -> { where(team_role: "backup") }

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

  def team_role_requires_user
    errors.add(:team_role, "requires a staff user") if team_role.present? && user_id.nil?
  end
end
