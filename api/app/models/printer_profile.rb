# frozen_string_literal: true

# A saved alignment/layout preset for a particular physical printer that an
# operator owns. Scoped to the user (not the company) because the same
# operator typically prints checks for several client companies on the same
# printer — the calibration shouldn't have to be redone per client.
class PrinterProfile < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :check_stock_type, inclusion: { in: %w[bottom_check top_check] }
  validates :check_offset_x, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validates :check_offset_y, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }

  scope :ordered, -> { order(:name) }

  # Only one default profile per user — the rest get cleared automatically
  # when a new default is set so we never end up with multiple defaults.
  after_save :clear_other_defaults, if: :is_default?

  private

  def clear_other_defaults
    self.class.transaction do
      PrinterProfile.where(user_id: user_id, is_default: true)
                    .where.not(id: id)
                    .update_all(is_default: false)
    end
  end
end
