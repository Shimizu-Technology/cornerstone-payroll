# frozen_string_literal: true

module FinanceBookOwned
  extend ActiveSupport::Concern

  included do
    belongs_to :finance_book, optional: true
    before_validation :assign_finance_book
    validate :finance_book_present_for_persisted_organization
    validate :finance_book_belongs_to_organization
    validate :finance_book_cannot_change, on: :update
  end

  private

  def assign_finance_book
    return if finance_book.present?

    self.finance_book = finance_book_parent&.finance_book
    self.finance_book ||= organization.finance_books.first if organization&.persisted? && organization.finance_books.one?
  end

  def finance_book_parent
    nil
  end

  def finance_book_belongs_to_organization
    return if finance_book.blank? || organization.blank? || finance_book.organization_id == organization_id

    errors.add(:finance_book, "must belong to the same organization")
  end

  def finance_book_present_for_persisted_organization
    return if organization.blank? || organization.new_record? || finance_book.present?

    errors.add(:finance_book, "must be selected")
  end

  def finance_book_cannot_change
    errors.add(:finance_book, "cannot be changed") if will_save_change_to_finance_book_id?
  end
end
