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

  def self.unresolved_reversed_for(company_id, tax_year: nil)
    records = where(company_id: company_id)
    records = records.where(tax_year: tax_year) if tax_year
    reversed = records.where(status: "reversed").where.not(tax_year: records.where(status: "active").select(:tax_year)).to_a
    where(id: reversed.reject(&:replaced_by_applied_ytd?).map(&:id))
  end

  # A replacement opening balance clears the hold only when it covers every
  # employee the undone history paid, through that employee's last paid date.
  # A partial replacement would let live payroll omit the others' wages.
  def replaced_by_applied_ytd?
    reversed_through = HistoricalPaycheck.where(historical_import_batch_id: historical_import_batch_id)
      .where.not(employee_id: nil).group(:employee_id).maximum(:pay_date)
    replacement = HistoricalEmployeeYtdBalance.joins(historical_ytd_bridge: :historical_import_batch)
      .where(company_id: company_id, tax_year: tax_year, historical_ytd_bridges: { company_id: company_id, status: "applied" },
        historical_import_batches: { company_id: company_id, status: "locked", importer_version: HistoricalImportBatch::YTD_BRIDGE_IMPORTER_VERSIONS })
    return replacement.exists? if reversed_through.empty?

    covered_through = replacement.where(employee_id: reversed_through.keys).group(:employee_id).maximum(:through_pay_date)
    reversed_through.all? { |employee_id, last_paid| covered_through[employee_id].present? && covered_through[employee_id] >= last_paid }
  end

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
