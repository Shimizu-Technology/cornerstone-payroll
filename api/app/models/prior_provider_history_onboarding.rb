# frozen_string_literal: true

class PriorProviderHistoryOnboarding < ApplicationRecord
  belongs_to :company
  belongs_to :historical_import_batch
  belongs_to :created_by, class_name: "User"
  belongs_to :activated_by, class_name: "User", optional: true
  belongs_to :reversed_by, class_name: "User", optional: true

  validates :status, inclusion: { in: %w[converted active reversed] }
  validates :idempotency_key, :preview_digest, :takeover_on, presence: true
  validates :idempotency_key, uniqueness: { scope: :company_id }, length: { maximum: 100 }
  validates :tax_year, inclusion: { in: 2000..2200 }
  validate :tenant_matches
  before_update :protect_evidence
  before_destroy :retain_evidence

  private

  def protect_evidence
    allowed = if status_in_database == "converted" && status == "active"
      %w[status activated_at activated_by_id filing_before filing_after updated_at]
    elsif status_in_database.in?(%w[converted active]) && status == "reversed"
      %w[status reversed_at reversed_by_id reversal_reason updated_at]
    else
      []
    end
    return if (changes_to_save.keys - allowed).empty?

    errors.add(:base, "Prior-provider source and review evidence is immutable")
    throw :abort
  end

  def tenant_matches
    errors.add(:historical_import_batch, "must belong to this client") if historical_import_batch&.company_id != company_id
  end

  def retain_evidence
    errors.add(:base, "Prior-provider onboarding evidence cannot be deleted")
    throw :abort
  end
end
