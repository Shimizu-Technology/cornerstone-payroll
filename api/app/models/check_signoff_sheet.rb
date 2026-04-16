class CheckSignoffSheet < ApplicationRecord
  belongs_to :pay_period
  belongs_to :company
  belongs_to :updated_by, class_name: "User", optional: true

  validates :pay_period_id, uniqueness: true
end
