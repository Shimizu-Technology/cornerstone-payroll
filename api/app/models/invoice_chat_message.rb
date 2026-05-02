# frozen_string_literal: true

class InvoiceChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze

  belongs_to :invoice_chat_session, touch: true

  before_validation :normalize_preview

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :content, presence: true

  private

  def normalize_preview
    self.content = content.to_s.strip
    self.image_urls = Array(image_urls).compact_blank
    self.preview = preview.presence || {}
    self.has_preview = preview.present? if has_preview.nil? || preview.present?
  end
end
