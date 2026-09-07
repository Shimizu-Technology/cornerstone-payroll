# frozen_string_literal: true

class HistoricalTaxWageReport < ApplicationRecord
  SCOPES = %w[quarterly quarterly_year_to_date annual year_to_date multi_year].freeze

  belongs_to :historical_import_batch
  belongs_to :historical_import_source_file
  belongs_to :company

  validates :scope, inclusion: { in: SCOPES }
  validates :source_position, :period_start, :period_end, :report_digest, presence: true
  validates :historical_import_source_file_id, uniqueness: true
  validate :tenant_and_source_match

  before_update :prevent_change
  before_destroy :prevent_change

  private

  def tenant_and_source_match
    return unless historical_import_batch && historical_import_source_file

    errors.add(:company, "must match the historical import") if company_id != historical_import_batch.company_id
    if historical_import_source_file.historical_import_batch_id != historical_import_batch_id
      errors.add(:historical_import_source_file, "must belong to the historical import")
    end
  end

  def prevent_change
    errors.add(:base, "Historical tax-and-wage evidence is immutable")
    throw(:abort)
  end
end
