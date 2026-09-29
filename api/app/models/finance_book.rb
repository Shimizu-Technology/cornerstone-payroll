# frozen_string_literal: true

class FinanceBook < ApplicationRecord
  KINDS = %w[organization client personal].freeze

  belongs_to :organization
  belongs_to :company, optional: true
  belongs_to :owner_user, class_name: "User", optional: true
  has_many :invoice_billing_profiles, dependent: :restrict_with_error
  has_many :invoice_recipients, dependent: :restrict_with_error
  has_many :invoices, dependent: :restrict_with_error
  has_many :invoice_chat_sessions, dependent: :restrict_with_error
  has_many :invoice_recurrences, dependent: :restrict_with_error
  has_many :invoice_send_schedules, dependent: :restrict_with_error
  has_many :expense_vendors, dependent: :restrict_with_error
  has_many :expenses, dependent: :restrict_with_error

  validates :name, :legal_name, presence: true
  validates :name, uniqueness: { scope: :organization_id, conditions: -> { where.not(kind: "personal") } }, unless: :personal?
  validates :kind, inclusion: { in: KINDS }
  validate :company_belongs_to_organization
  validate :client_book_has_company
  validate :personal_book_ownership

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(is_default: :desc, name: :asc, id: :asc) }
  scope :accessible_to, ->(user) { where("kind <> 'personal' OR owner_user_id = ?", user.id) }

  def personal?
    kind == "personal"
  end

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

  def personal_book_ownership
    if kind == "personal"
      errors.add(:owner_user, "is required for a personal book") if owner_user.blank?
      if owner_user && organization && !owner_user.super_admin? && owner_user.organization_id != organization_id
        errors.add(:owner_user, "must belong to the book's organization")
      end
      errors.add(:company, "is not allowed for a personal book") if company.present?
      errors.add(:is_default, "is not allowed for a personal book") if is_default?
    elsif owner_user.present?
      errors.add(:owner_user, "is only allowed for a personal book")
    end
  end
end
