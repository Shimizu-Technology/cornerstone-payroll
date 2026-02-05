# frozen_string_literal: true

class Company < ApplicationRecord
  has_many :departments, dependent: :destroy
  has_many :employees, dependent: :destroy
  has_many :pay_periods, dependent: :destroy
  has_many :deduction_types, dependent: :destroy
  has_many :company_ytd_totals, dependent: :destroy

  validates :name, presence: true
  validates :ein, uniqueness: true, allow_blank: true
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }

  scope :active, -> { where(active: true) }

  def full_address
    [ address_line1, address_line2, "#{city}, #{state} #{zip}" ].compact_blank.join("\n")
  end
end
