# frozen_string_literal: true

class CompanyAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :company

  validates :user_id, uniqueness: { scope: :company_id }
end
