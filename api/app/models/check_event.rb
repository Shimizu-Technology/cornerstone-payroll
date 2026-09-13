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
  DELIVERY_EVIDENCE_TYPES = %w[hand_delivery mail courier other].freeze

  validates :event_type, inclusion: { in: VALID_EVENT_TYPES }
  validates :check_number, presence: true
  validates :effective_on, presence: true
  validates :evidence_type, inclusion: { in: DELIVERY_EVIDENCE_TYPES }, allow_nil: true
  validate :effective_date_is_not_in_the_future
  validate :user_belongs_to_payroll_organization

  before_validation :default_effective_on
  before_update :prevent_mutation
  before_destroy :prevent_mutation

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

  def default_effective_on
    self.effective_on ||= PayrollBusinessClock.today
  end

  def prevent_mutation
    errors.add(:base, "Check event history is append-only")
    throw :abort
  end

  def effective_date_is_not_in_the_future
    errors.add(:effective_on, "cannot be in the future") if effective_on.present? && effective_on > PayrollBusinessClock.today
  end

  def user_belongs_to_payroll_organization
    return if user.blank? || payroll_item.blank?
    return if user.organization_id == payroll_item.company.organization_id

    errors.add(:user, "must belong to the payroll company's organization")
  end

  def record_aire_entry_lifecycle
    status = aire_entry_lifecycle_status
    return unless status

    @aire_entry_acknowledgement_ids = AirePayrollEntryAcknowledgement
      .record_for_check_event!(check_event: self, status: status)
      .map(&:id)
  end

  def dispatch_aire_entry_lifecycle
    return if @aire_entry_acknowledgement_ids.blank?

    AirePayrollEntryAcknowledgement.dispatch_pending!(ids: @aire_entry_acknowledgement_ids)
  end

  def aire_entry_lifecycle_status
    return "payment_prepared" if event_type == "printed"
    return "payment_issued" if event_type == "delivered"
    return "payment_voided" if event_type == "voided" && payroll_item.voided?
    return "payment_issued" if event_type == "voided" && payroll_item.check_status == "delivered"
    "payment_prepared" if event_type == "voided" && payroll_item.check_status == "printed"
  end
end
