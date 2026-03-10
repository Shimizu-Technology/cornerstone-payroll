# frozen_string_literal: true

class CheckEvent < ApplicationRecord
  belongs_to :payroll_item
  belongs_to :user

  VALID_EVENT_TYPES = %w[printed voided reprinted batch_downloaded].freeze

  validates :event_type, inclusion: { in: VALID_EVENT_TYPES }
  validates :check_number, presence: true

  scope :for_check,   ->(number) { where(check_number: number) }
  scope :prints,      -> { where(event_type: "printed") }
  scope :voids,       -> { where(event_type: "voided") }
  scope :reprints,    -> { where(event_type: "reprinted") }
end
