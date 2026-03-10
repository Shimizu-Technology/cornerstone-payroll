# frozen_string_literal: true

class Company < ApplicationRecord
  has_many :departments, dependent: :destroy
  has_many :employees, dependent: :destroy
  has_many :pay_periods, dependent: :destroy
  has_many :deduction_types, dependent: :destroy
  has_many :company_ytd_totals, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :user_invitations, dependent: :destroy

  validates :name, presence: true
  validates :ein, uniqueness: true, allow_blank: true
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :check_stock_type, inclusion: { in: %w[bottom_check top_check] }

  scope :active, -> { where(active: true) }

  # ---------------------------------------------------------------------------
  # Check number sequencing — thread-safe via row-level lock
  # ---------------------------------------------------------------------------

  # Assign check numbers to a set of payroll_items (unsaved or without check #).
  # All assignments happen inside a single locked transaction — no collisions.
  # @param items [ActiveRecord::Relation or Array<PayrollItem>] items needing a check #
  # @return [Integer] the number of check numbers assigned
  def assign_check_numbers!(items)
    items = items.to_a
    return 0 if items.empty?

    assigned = 0
    self.class.transaction do
      lock!  # SELECT … FOR UPDATE on this company row
      starting = next_check_number
      items.each_with_index do |item, idx|
        item.update_column(:check_number, (starting + idx).to_s)
        assigned += 1
      end
      update_column(:next_check_number, starting + assigned)
    end
    assigned
  rescue ActiveRecord::StatementInvalid => e
    if e.message.include?("index_payroll_items_on_check_number") || e.message.downcase.include?("unique")
      raise ArgumentError, "Check number collision detected while assigning checks. Please verify company check settings and retry."
    end
    raise
  end

  # Reserve exactly one check number (for reprint flow).
  # @return [String] the newly reserved check number string
  def next_check_number!
    reserved = nil
    self.class.transaction do
      lock!
      reserved = next_check_number.to_s
      update_column(:next_check_number, next_check_number + 1)
    end
    reserved
  end

  def full_address
    [ address_line1, address_line2, "#{city}, #{state} #{zip}" ].compact_blank.join("\n")
  end
end
