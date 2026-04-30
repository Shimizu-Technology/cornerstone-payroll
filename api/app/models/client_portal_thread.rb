# frozen_string_literal: true

class ClientPortalThread < ApplicationRecord
  STATUSES = %w[open resolved].freeze

  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :resolved_by, class_name: "User", optional: true
  has_many :messages,
    class_name: "ClientPortalMessage",
    dependent: :destroy,
    inverse_of: :client_portal_thread

  validates :subject, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(Arel.sql("COALESCE(last_message_at, created_at) DESC")) }
  scope :open, -> { where(status: "open") }

  def resolved?
    status == "resolved"
  end

  def open?
    status == "open"
  end

  def mark_read_for!(user)
    return unless user

    if staff_user?(user)
      update!(staff_last_read_at: Time.current)
    else
      update!(client_last_read_at: Time.current)
    end
  end

  def unread_for?(user)
    return false unless user && last_message_at

    read_at = staff_user?(user) ? staff_last_read_at : client_last_read_at
    read_at.blank? || read_at < last_message_at
  end

  def self.staff_user?(user)
    user&.admin? || user&.manager? || user&.accountant?
  end

  private

  def staff_user?(user)
    self.class.staff_user?(user)
  end
end
