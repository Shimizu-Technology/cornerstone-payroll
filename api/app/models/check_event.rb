# frozen_string_literal: true

class CheckEvent < ApplicationRecord
  belongs_to :payroll_item
  belongs_to :user, optional: true
  has_many :aire_payroll_entry_acknowledgements, dependent: :restrict_with_error

  # `replaced` covers the "void + cut new check at corrected amount" flow used
  # when the original check was uncashed (operator has it in hand or it was
  # never given out). The void of the old check # is logged separately as a
  # `voided` event for backwards compatibility with existing reports.
  VALID_EVENT_TYPES = %w[assigned printed delivered voided reprinted batch_downloaded replaced renumbered].freeze

  validates :event_type, inclusion: { in: VALID_EVENT_TYPES }
  validates :check_number, presence: true

  scope :for_check,   ->(number) { where(check_number: number) }
  scope :assignments, -> { where(event_type: "assigned") }
  scope :prints,      -> { where(event_type: "printed") }
  scope :deliveries,  -> { where(event_type: "delivered") }
  scope :voids,       -> { where(event_type: "voided") }
  scope :reprints,    -> { where(event_type: "reprinted") }
  scope :replacements, -> { where(event_type: "replaced") }
  scope :renumberings, -> { where(event_type: "renumbered") }

  after_create :record_aire_entry_lifecycle
  after_create_commit :dispatch_aire_entry_lifecycle

  private

  def record_aire_entry_lifecycle
    status = {
      "printed" => "payment_prepared",
      "delivered" => "payment_issued",
      "voided" => "payment_voided"
    }[event_type]
    return unless status

    @aire_entry_acknowledgement_ids = AirePayrollEntryAcknowledgement
      .record_for_check_event!(check_event: self, status: status)
      .map(&:id)
  end

  def dispatch_aire_entry_lifecycle
    return if @aire_entry_acknowledgement_ids.blank?

    AirePayrollEntryAcknowledgement.dispatch_pending!(ids: @aire_entry_acknowledgement_ids)
  end
end
