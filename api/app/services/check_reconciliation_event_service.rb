# frozen_string_literal: true

class CheckReconciliationEventService
  class Error < StandardError; end

  def initialize(company:, actor:, attributes:)
    @company = company
    @actor = actor
    @attributes = attributes.to_h.symbolize_keys
  end

  def call
    validate_idempotency_key!
    existing = company.check_reconciliation_events.find_by(idempotency_key: attributes[:idempotency_key])
    return verify_replay!(existing) if existing

    source = resolve_source!
    event = nil
    source.with_lock do
      status = CheckReconciliationStatus.for(source)
      validate_transition!(source, status)
      event = ActiveRecord::Base.transaction(requires_new: true) { create_event!(source) }
    end
    event
  rescue ActiveRecord::RecordNotUnique
    existing = company.check_reconciliation_events.find_by!(idempotency_key: attributes[:idempotency_key])
    verify_replay!(existing)
  rescue Date::Error
    raise Error, "Effective date is invalid"
  end

  private

  attr_reader :company, :actor, :attributes

  def validate_idempotency_key!
    key = attributes[:idempotency_key].to_s
    raise Error, "Idempotency key is required" if key.blank?
    raise Error, "Idempotency key is too long" if key.length > 100
  end

  def resolve_source!
    case attributes[:source_type]
    when "payroll_item"
      PayrollItem.find_by!(id: attributes[:source_id], company_id: company.id)
    when "non_employee_check"
      NonEmployeeCheck.find_by!(id: attributes[:source_id], company_id: company.id)
    else
      raise Error, "Check source type is invalid"
    end
  rescue ActiveRecord::RecordNotFound
    raise Error, "Check not found"
  end

  def validate_transition!(source, status)
    if source.is_a?(NonEmployeeCheck) && source.non_employee_check_supersession
      raise Error, "This software check is linked to a payroll check; reconcile the payroll check instead"
    end
    raise Error, "Only paper checks can be reconciled" if source.is_a?(NonEmployeeCheck) && source.payment_method != "check"
    raise Error, "Check number is required" if source.check_number.blank?
    raise Error, "Effective date cannot be in the future" if parsed_effective_on > PayrollBusinessClock.today

    case attributes[:event_type]
    when "cleared"
      raise Error, "Only an issued check can be marked cleared" unless status == "issued"
      validate_clearing_evidence!
      validate_not_before_issue!(source)
    when "clearing_reversed"
      raise Error, "Only a cleared check can have clearing reversed" unless status == "cleared"
      validate_reason!
      validate_not_before_clearing!(source)
    when "replacement_required"
      raise Error, "Only an issued check can require replacement" unless status == "issued"
      validate_reason!
      validate_not_before_issue!(source)
    else
      raise Error, "Reconciliation event type is invalid"
    end
  end

  def validate_clearing_evidence!
    unless CheckReconciliationEvent::EVIDENCE_TYPES.include?(attributes[:evidence_type].to_s)
      raise Error, "Select the clearing evidence source"
    end
    raise Error, "Evidence reference is required" if attributes[:evidence_reference].to_s.strip.blank?
  end

  def validate_reason!
    raise Error, "Reason must be at least 10 characters" if attributes[:reason].to_s.strip.length < 10
  end

  def validate_not_before_issue!(source)
    effective_on = parsed_effective_on
    issued_on = if source.is_a?(PayrollItem)
      source.check_events.where(event_type: "delivered", check_number: source.check_number).maximum(:effective_on)
    else
      source.payment_date
    end
    return if issued_on.blank? || effective_on >= issued_on

    raise Error, "Effective date cannot be before the issue date"
  end

  def validate_not_before_clearing!(source)
    cleared_event = source.check_reconciliation_events
      .for_instrument(source, source.check_number)
      .where(event_type: "cleared")
      .order(created_at: :desc, id: :desc)
      .first
    return if cleared_event.blank? || parsed_effective_on >= cleared_event.effective_on

    raise Error, "Correction date cannot be before the cleared date"
  end

  def create_event!(source)
    company.check_reconciliation_events.create!(
      pay_period: source.pay_period,
      payroll_item: source.is_a?(PayrollItem) ? source : nil,
      non_employee_check: source.is_a?(NonEmployeeCheck) ? source : nil,
      recorded_by: actor,
      event_type: attributes[:event_type],
      check_number: source.check_number,
      amount: source.is_a?(PayrollItem) ? source.net_pay : source.amount,
      effective_on: parsed_effective_on,
      evidence_type: attributes[:evidence_type].to_s.presence,
      evidence_reference: attributes[:evidence_reference].to_s.strip.presence,
      reason: attributes[:reason].to_s.strip.presence,
      idempotency_key: attributes[:idempotency_key]
    )
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  def parsed_effective_on
    @parsed_effective_on ||= Date.iso8601(attributes[:effective_on].to_s)
  end

  def verify_replay!(event)
    expected_source = attributes[:source_type] == "payroll_item" ? event.payroll_item_id : event.non_employee_check_id
    same = event.event_type == attributes[:event_type].to_s &&
      expected_source == attributes[:source_id].to_i &&
      event.effective_on == parsed_effective_on &&
      event.evidence_type == attributes[:evidence_type].to_s.presence &&
      event.evidence_reference == attributes[:evidence_reference].to_s.strip.presence &&
      event.reason == attributes[:reason].to_s.strip.presence
    raise Error, "Idempotency key was already used for a different reconciliation action" unless same

    event
  end
end
