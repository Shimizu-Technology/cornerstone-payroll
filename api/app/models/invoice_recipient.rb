# frozen_string_literal: true

class InvoiceRecipient < ApplicationRecord
  belongs_to :organization
  belongs_to :company, optional: true
  has_many :invoices, dependent: :restrict_with_error

  before_validation :normalize_blanks
  before_validation :default_organization_from_company

  validates :name, presence: true
  validates :default_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :template_type, inclusion: { in: %w[standard hourly project tuition] }
  validate :company_must_belong_to_organization

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name, :id) }

  private

  def normalize_blanks
    self.email = email.to_s.strip.presence
    self.address = address.to_s.strip.presence
    self.invoice_prefix = invoice_prefix.to_s.strip.presence
    self.payment_terms = payment_terms.to_s.strip.presence
    self.notes = notes.to_s.strip.presence
    self.template_type = template_type.presence || "standard"
  end

  def default_organization_from_company
    self.organization ||= company&.organization
  end

  def company_must_belong_to_organization
    return if company.blank? || organization.blank?
    return if company.organization_id == organization_id

    errors.add(:company, "must belong to the recipient's organization")
  end
end
