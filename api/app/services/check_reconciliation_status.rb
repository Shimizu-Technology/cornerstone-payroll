# frozen_string_literal: true

class CheckReconciliationStatus
  STATUSES = %w[unprepared prepared issued cleared replacement_required voided].freeze

  def self.for(source)
    new(source).call
  end

  def initialize(source)
    @source = source
  end

  def call
    return "voided" if source.voided?

    event = latest_reconciliation_event
    return "cleared" if event&.event_type == "cleared"
    return "replacement_required" if event&.event_type == "replacement_required"

    return employee_base_status if source.is_a?(PayrollItem)

    non_employee_base_status
  end

  private

  attr_reader :source

  def latest_reconciliation_event
    events = source.check_reconciliation_events
    records = events.loaded? ? events.target : events.where(check_number: source.check_number).to_a
    records
      .select { |event| event.check_number == source.check_number }
      .max_by { |event| [ event.created_at, event.id ] }
  end

  def employee_base_status
    events = source.check_events
    delivered = if events.loaded?
      events.any? { |event| event.event_type == "delivered" && event.check_number == source.check_number }
    else
      events.where(event_type: "delivered", check_number: source.check_number).exists?
    end
    return "issued" if delivered
    return "prepared" if source.check_printed_at.present?

    "unprepared"
  end

  def non_employee_base_status
    return "issued" if source.paid_at.present?
    return "prepared" if source.printed?

    "unprepared"
  end
end
