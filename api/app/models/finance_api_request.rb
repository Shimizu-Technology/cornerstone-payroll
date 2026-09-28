# frozen_string_literal: true

class FinanceApiRequest < ApplicationRecord
  belongs_to :organization
  belongs_to :finance_book
  belongs_to :finance_api_token
  belongs_to :invoice, optional: true

  validates :idempotency_key, presence: true, length: { maximum: 128 }
  validates :request_digest, presence: true
  validate :matching_scope

  private

  def matching_scope
    return if organization.blank? || finance_book.blank? || finance_api_token.blank?

    errors.add(:finance_book, "has a different organization") if finance_book.organization_id != organization_id
    errors.add(:finance_api_token, "has a different financial book") if finance_api_token.finance_book_id != finance_book_id
    errors.add(:invoice, "has a different financial book") if invoice && invoice.finance_book_id != finance_book_id
  end
end
