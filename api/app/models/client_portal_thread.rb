# frozen_string_literal: true

class ClientPortalThread < ApplicationRecord
  include PortalInboxUpdates
  attr_readonly :created_by_audience, :created_by_name_snapshot
  before_validation :snapshot_creator_origin, on: :create
  validates :created_by_audience, inclusion: { in: %w[client staff unknown] }
  STATUSES = %w[open resolved].freeze

  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :resolved_by, class_name: "User", optional: true
  has_many :messages,
    class_name: "ClientPortalMessage",
    dependent: :destroy,
    inverse_of: :client_portal_thread

  validates :idempotency_key, length: { maximum: 128 }, allow_nil: true
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
  has_many :file_requests, class_name: "PortalFileRequest", dependent: :restrict_with_error

  def read_cursor_for(user)
    [ read_baseline_message_id, read_receipts.find_by(user_id: user.id)&.last_displayed_message_id || 0 ].max
  end

  # The cursor moves only through messages the user was shown. An unshown
  # message from someone else stops it, so that message stays unread.
  def mark_read_for!(user, displayed_message_ids:)
    with_lock do
      shown = displayed_message_ids.map(&:to_i).to_set
      raise ActiveRecord::RecordNotFound, "Message not in this conversation" if messages.where(id: shown.to_a).count != shown.size

      cursor = read_cursor_for(user)
      reached = cursor
      messages.where("id > ?", cursor).order(:id).pluck(:id, :author_id, :created_at).each do |id, author_id, created_at|
        counts_as_unread = author_id != user.id && created_at >= user.created_at
        break if counts_as_unread && !shown.include?(id)

        reached = id
      end
      return false if reached <= cursor

      receipt = read_receipts.find_or_initialize_by(user: user)
      receipt.update!(last_displayed_message_id: reached, opened_at: Time.current)
      update!(self.class.staff_user?(user) ? { staff_last_read_at: Time.current } : { client_last_read_at: Time.current })
      true
    end
  end

  def unread_for?(user, cursor: nil)
    return false unless user

    cursor ||= read_cursor_for(user)
    messages.loaded? ? messages.any? { |message| message.id > cursor && message.author_id != user.id && message.created_at >= user.created_at } : messages.where("id > ? AND author_id IS DISTINCT FROM ? AND created_at >= ?", cursor, user.id, user.created_at).exists?
  end

  def self.unread_count_for(user, company_id:, status: nil)
    scope = where(company_id: company_id)
    scope = scope.where(status: status) if status.present?
    scope.where(<<~SQL.squish, user.id, user.created_at, user.id).count
      EXISTS (SELECT 1 FROM client_portal_messages m
        WHERE m.client_portal_thread_id = client_portal_threads.id
        AND m.author_id IS DISTINCT FROM ? AND m.created_at >= ?
        AND m.id > GREATEST(client_portal_threads.read_baseline_message_id,
          COALESCE((SELECT r.last_displayed_message_id FROM portal_thread_read_receipts r
            WHERE r.client_portal_thread_id = client_portal_threads.id AND r.user_id = ?), 0)))
    SQL
  end

  def self.staff_user?(user)
    user&.staff_member?
  end

  private

  def snapshot_creator_origin
    self.created_by_audience = created_by&.client? ? "client" : created_by&.staff_member? ? "staff" : "unknown"
    self.created_by_name_snapshot = created_by&.name
  end

  def staff_user?(user)
    self.class.staff_user?(user)
  end
end
