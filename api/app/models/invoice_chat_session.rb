# frozen_string_literal: true

class InvoiceChatSession < ApplicationRecord
  STATUSES = %w[active invoice_created archived].freeze

  belongs_to :organization
  belongs_to :company, optional: true
  belongs_to :invoice_recipient, optional: true
  belongs_to :invoice, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many :messages,
           -> { order(:created_at, :id) },
           class_name: "InvoiceChatMessage",
           dependent: :destroy,
           inverse_of: :invoice_chat_session

  before_validation :normalize_blanks

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :recipient_must_belong_to_organization
  validate :invoice_must_belong_to_organization

  scope :recent, -> { order(updated_at: :desc, created_at: :desc) }

  def archive!(actor:)
    update!(archived: true, status: "archived", updated_by: actor)
  end

  def store_preview!(preview, actor:)
    next_version = current_preview_version.to_i + 1
    update!(
      current_preview: preview.presence || {},
      current_preview_version: next_version,
      updated_by: actor
    )
    next_version
  end

  private

  def normalize_blanks
    self.organization ||= company&.organization
    self.title = title.to_s.strip.presence || "Invoice Assistant"
    self.status = status.presence || "active"
    self.current_preview = current_preview.presence || {}
    self.archived = false if archived.nil?
  end

  def recipient_must_belong_to_organization
    return if invoice_recipient.blank? || organization_id.blank?
    return if invoice_recipient.organization_id == organization_id

    errors.add(:invoice_recipient, "must belong to the same organization")
  end

  def invoice_must_belong_to_organization
    return if invoice.blank? || organization_id.blank?
    return if invoice.organization_id == organization_id

    errors.add(:invoice, "must belong to the same organization")
  end
end
