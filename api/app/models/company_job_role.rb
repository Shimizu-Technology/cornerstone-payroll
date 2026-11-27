# frozen_string_literal: true

class CompanyJobRole < ApplicationRecord
  CODES = JSON.parse(Rails.root.join("config/tipped_occupation_codes.json").read).fetch("codes").freeze

  belongs_to :company
  has_many :employees
  normalizes :name, with: ->(name) { name.strip }
  normalizes :occupation_code, with: ->(code) { code.strip.presence }

  validates :name, presence: true, length: { maximum: 255 }, uniqueness: { scope: :company_id }
  validates :occupation_code, inclusion: { in: CODES.keys }, allow_nil: true
end
