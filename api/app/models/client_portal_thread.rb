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

  scope :recent_first, -> { order(Arel.sql("COALESCE(client_portal_threads.last_message_at, client_portal_threads.created_at) DESC, client_portal_threads.id DESC")) }
  scope :open, -> { where(status: "open") }

  def resolved?
    status == "resolved"
  end

  def open?
    status == "open"
  end

  has_many :read_receipts, class_name: "PortalThreadReadReceipt", dependent: :delete_all

  def read_cursor_for(user)
    [ read_baseline_message_id, read_receipts.find_by(user_id: user.id)&.last_displayed_message_id || 0 ].max
  end

  def mark_read_for!(user, last_displayed_message_id:)
    with_lock do
      message = messages.find(last_displayed_message_id)
      receipt = read_receipts.find_or_initialize_by(user: user)
      return false if message.id <= read_cursor_for(user)

      receipt.update!(last_displayed_message_id: message.id, opened_at: Time.current)
      update!(self.class.staff_user?(user) ? { staff_last_read_at: Time.current } : { client_last_read_at: Time.current })
      true
    end
  end

  def unread_for?(user, cursor: nil)
    return false unless user

    cursor ||= read_cursor_for(user)
    messages.loaded? ? messages.any? { |message| message.id > cursor } : messages.where("id > ?", cursor).exists?
  end

  def self.unread_count_for(user, company_id:, status: nil)
    scope = where(company_id: company_id)
    scope = scope.where(status: status) if status.present?
    scope.where(<<~SQL.squish, user.id).count
      EXISTS (SELECT 1 FROM client_portal_messages m
        WHERE m.client_portal_thread_id = client_portal_threads.id
        AND m.id > GREATEST(client_portal_threads.read_baseline_message_id,
          COALESCE((SELECT r.last_displayed_message_id FROM portal_thread_read_receipts r
            WHERE r.client_portal_thread_id = client_portal_threads.id AND r.user_id = ?), 0)))
    SQL
  end

  def self.staff_user?(user)
    user&.staff_member?
  end

  private

  def staff_user?(user)
    self.class.staff_user?(user)
  end
end
