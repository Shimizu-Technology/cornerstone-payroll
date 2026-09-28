# frozen_string_literal: true

class FinanceBook < ApplicationRecord
  KINDS = %w[organization client].freeze

  belongs_to :organization
  belongs_to :company, optional: true
  has_many :invoice_billing_profiles, dependent: :restrict_with_error
  has_many :invoice_recipients, dependent: :restrict_with_error
  has_many :invoices, dependent: :restrict_with_error
  has_many :invoice_chat_sessions, dependent: :restrict_with_error
  has_many :invoice_recurrences, dependent: :restrict_with_error
  has_many :invoice_send_schedules, dependent: :restrict_with_error
  has_many :expense_vendors, dependent: :restrict_with_error
  has_many :expenses, dependent: :restrict_with_error

  validates :name, :legal_name, presence: true
  validates :name, uniqueness: { scope: :organization_id }
  validates :kind, inclusion: { in: KINDS }
  validate :company_belongs_to_organization
  validate :client_book_has_company

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(is_default: :desc, name: :asc, id: :asc) }

  def self.default_for!(organization)
    organization.with_lock do
      organization.finance_books.find_or_create_by!(is_default: true) do |book|
        book.name = organization.name
        book.legal_name = organization.name
        book.kind = "organization"
      end
    end
  end

  private

  def company_belongs_to_organization
    return if company.blank? || organization.blank? || company.organization_id == organization_id

    errors.add(:company, "must belong to the book's organization")
  end

  def client_book_has_company
    errors.add(:company, "is required for a client book") if kind == "client" && company.blank?
  end
end
