# frozen_string_literal: true

# How a Cornerstone Tax client counts in Payroll: as one Payroll client
# (company, the record invoices and fees are keyed by) or as the practice's own
# internal/overhead time.
class WorkHourClientLink < ApplicationRecord
  DISPOSITIONS = %w[company internal].freeze

  belongs_to :organization
  belongs_to :company, optional: true
  belongs_to :linked_by, class_name: "User", optional: true

  validates :tax_client_id, presence: true, uniqueness: { scope: :organization_id }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validate :company_matches_disposition

  private

  def company_matches_disposition
    if disposition == "company"
      if company.nil?
        errors.add(:company, "must be chosen")
      elsif company.organization_id != organization_id || !company.live_payroll?
        errors.add(:company, "must be a live client in this organization")
      end
    elsif company_id.present?
      errors.add(:company, "must be empty for internal time")
    end
  end
end
