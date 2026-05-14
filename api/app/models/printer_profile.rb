# frozen_string_literal: true

# A saved alignment/layout preset for a particular physical printer.
# Scoped to the organization so everyone in the same accounting firm can reuse
# the same calibration across that firm's client companies.
class PrinterProfile < ApplicationRecord
  belongs_to :organization

  validates :name, presence: true, uniqueness: { scope: :organization_id }
  validates :check_stock_type, inclusion: { in: Company::CHECK_STOCK_TYPES }
  validates :check_offset_x, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validates :check_offset_y, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }

  scope :ordered, -> { order(:name) }

  # Only one default profile per organization — the rest get cleared automatically
  # when a new default is set so we never end up with multiple defaults.
  after_save :clear_other_defaults, if: :is_default?

  private

  def clear_other_defaults
    self.class.transaction do
      PrinterProfile.where(organization_id: organization_id, is_default: true)
                    .where.not(id: id)
                    .update_all(is_default: false)
    end
  end
end
