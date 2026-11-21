# frozen_string_literal: true

# One row per organization: which company runs the practice's own staff
# payroll (the cost side), which financial book holds the practice's client
# invoices (the fee side), and which saved services count as tax preparation.
class ClientProfitabilitySetting < ApplicationRecord
  belongs_to :organization
  belongs_to :practice_company, class_name: "Company", optional: true
  belongs_to :finance_book, optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  before_validation :normalize_tax_prep_service_names

  validates :organization_id, uniqueness: true
  validate :practice_company_is_live_in_organization
  validate :finance_book_is_shared_in_organization
  validate :tax_prep_service_names_are_strings

  def self.for(organization)
    find_or_initialize_by(organization: organization)
  end

  # The book whose invoices supply fees: the saved choice, otherwise the
  # organization's default (or only) shared book.
  def effective_finance_book
    return finance_book if finance_book&.active?

    books = FinanceBook.active.where(organization_id: organization_id).where.not(kind: "personal")
    books.find_by(is_default: true) || (books.one? ? books.first : nil)
  end

  def tax_prep_service_key_set
    tax_prep_service_names.map { |name| self.class.service_key(name) }.to_set
  end

  def self.service_key(name)
    name.to_s.squish.downcase
  end

  private

  def normalize_tax_prep_service_names
    names = Array(tax_prep_service_names).filter_map { |name| name.is_a?(String) ? name.squish.presence : name }
    self.tax_prep_service_names = names.uniq { |name| self.class.service_key(name) }.first(100)
  end

  def tax_prep_service_names_are_strings
    errors.add(:tax_prep_service_names, "must be a list of service names") unless tax_prep_service_names.all?(String)
  end

  def practice_company_is_live_in_organization
    return if practice_company.nil?
    return if practice_company.organization_id == organization_id && practice_company.live_payroll?

    errors.add(:practice_company, "must be a live client in this organization")
  end

  def finance_book_is_shared_in_organization
    return if finance_book.nil?
    return if finance_book.organization_id == organization_id && !finance_book.personal?

    errors.add(:finance_book, "must be a shared financial book in this organization")
  end
end
