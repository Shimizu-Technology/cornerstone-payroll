# frozen_string_literal: true

class Department < ApplicationRecord
  belongs_to :company
  has_many :employees, dependent: :nullify
  has_many :department_ytd_totals, dependent: :destroy

  validates :name, presence: true
  validates :name, uniqueness: { scope: :company_id }

  scope :active, -> { where(active: true) }
end
