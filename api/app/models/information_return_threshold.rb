# frozen_string_literal: true

class InformationReturnThreshold < ApplicationRecord
  FORM_TYPES = %w[1099_nec].freeze

  validates :form_type, inclusion: { in: FORM_TYPES }
  validates :tax_year, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 2000 }
  validates :tax_year, uniqueness: { scope: :form_type }
  validates :threshold_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :source_url, :effective_on, presence: true

  def self.for!(form_type:, tax_year:)
    find_by!(form_type: form_type.to_s, tax_year: tax_year.to_i)
  rescue ActiveRecord::RecordNotFound
    raise ArgumentError, "No #{form_type} reporting threshold is configured for #{tax_year}"
  end
end
