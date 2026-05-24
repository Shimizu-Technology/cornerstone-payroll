# frozen_string_literal: true

class CheckEvent < ApplicationRecord
  belongs_to :payroll_item
  belongs_to :user, optional: true

  # `replaced` covers the "void + cut new check at corrected amount" flow used
  # when the original check was uncashed (operator has it in hand or it was
  # never given out). The void of the old check # is logged separately as a
  # `voided` event for backwards compatibility with existing reports.
  VALID_EVENT_TYPES = %w[assigned printed voided reprinted batch_downloaded replaced renumbered].freeze

  validates :event_type, inclusion: { in: VALID_EVENT_TYPES }
  validates :check_number, presence: true

  scope :for_check,   ->(number) { where(check_number: number) }
  scope :assignments, -> { where(event_type: "assigned") }
  scope :prints,      -> { where(event_type: "printed") }
  scope :voids,       -> { where(event_type: "voided") }
  scope :reprints,    -> { where(event_type: "reprinted") }
  scope :replacements, -> { where(event_type: "replaced") }
  scope :renumberings, -> { where(event_type: "renumbered") }
end
