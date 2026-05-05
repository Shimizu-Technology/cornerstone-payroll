# frozen_string_literal: true

class TimeTrackingSource < ApplicationRecord
  SOURCE_TYPES = %w[aire_services cornerstone_tax custom].freeze

  belongs_to :company
  has_many :time_tracking_employee_mappings, dependent: :destroy
  has_many :time_tracking_imports, dependent: :destroy

  encrypts :shared_secret

  validates :name, :source_type, :base_url, :shared_secret, presence: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :name, uniqueness: { scope: :company_id }

  scope :active, -> { where(active: true) }
end
