# frozen_string_literal: true

class PrinterProfile < ApplicationRecord
  belongs_to :company

  validates :name, presence: true, uniqueness: { scope: :company_id }
  validates :check_stock_type, inclusion: { in: %w[bottom_check top_check] }
  validates :check_offset_x, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validates :check_offset_y, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }

  scope :ordered, -> { order(:name) }

  # When a profile is set as default, clear default on all others for this company
  after_save :clear_other_defaults, if: :is_default?

  private

  def clear_other_defaults
    self.class.transaction do
      PrinterProfile.where(company_id: company_id, is_default: true)
                    .where.not(id: id)
                    .update_all(is_default: false)
    end
  end
end
