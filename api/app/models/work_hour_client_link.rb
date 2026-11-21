# frozen_string_literal: true

# How a Cornerstone Tax client counts in Payroll: as one Payroll client
# (company, the record invoices and fees are keyed by), as an invoice customer
# with no Payroll client (recipient; fees on that customer's invoices), or as
# the practice's own internal/overhead time.
class WorkHourClientLink < ApplicationRecord
  DISPOSITIONS = %w[company recipient internal].freeze

  belongs_to :organization
  belongs_to :company, optional: true
  belongs_to :invoice_recipient, optional: true
  belongs_to :linked_by, class_name: "User", optional: true

  # Unlinking deactivates the row (keeping who linked it and when);
  # relinking reactivates the same row.
  scope :active, -> { where(active: true) }

  validates :tax_client_id, presence: true, uniqueness: { scope: :organization_id }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validate :company_matches_disposition
  validate :recipient_matches_disposition

  private

  def company_matches_disposition
    if disposition == "company"
      if company.nil?
        errors.add(:company, "must be chosen")
      elsif company.organization_id != organization_id || !company.live_payroll?
        errors.add(:company, "must be a live client in this organization")
      end
    elsif company_id.present?
      errors.add(:company, "must be empty unless linking to a Payroll client")
    end
  end

  # Only a customer with no Payroll client: one that has a Payroll client is
  # linked through that client, so its fees aren't counted twice.
  def recipient_matches_disposition
    if disposition == "recipient"
      if invoice_recipient.nil?
        errors.add(:invoice_recipient, "must be chosen")
      elsif invoice_recipient.organization_id != organization_id || invoice_recipient.finance_book&.personal?
        errors.add(:invoice_recipient, "must be an invoice customer in this organization")
      elsif invoice_recipient.company_id.present?
        errors.add(:invoice_recipient, "has a Payroll client; link to that client instead")
      end
    elsif invoice_recipient_id.present?
      errors.add(:invoice_recipient, "must be empty unless linking to an invoice customer")
    end
  end
end
