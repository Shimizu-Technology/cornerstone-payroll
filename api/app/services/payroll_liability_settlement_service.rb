# frozen_string_literal: true

class PayrollLiabilitySettlementService
  class Error < StandardError; end
  class InvalidStateError < Error; end

  def self.record!(...)
    new(...).record!
  end

  def self.reverse!(...)
    new(...).reverse!
  end

  def initialize(pay_period:, actor:, authority: nil, category: nil, amount: nil,
                 payment_date: nil, payment_method: nil, confirmation_number: nil,
                 notes: nil, reason: nil, idempotency_key: nil, source_payment: nil)
    @pay_period = pay_period
    @actor = actor
    @authority = authority.to_s.strip
    @category = category.to_s
    @amount = amount
    @payment_date = payment_date
    @payment_method = payment_method.to_s
    @confirmation_number = confirmation_number.to_s.strip.presence
    @notes = notes.to_s.strip.presence
    @reason = reason.to_s.strip.presence
    @idempotency_key = idempotency_key.to_s.strip.presence
    @source_payment = source_payment
  end

  def record!
    PayPeriod.transaction do
      period = locked_period!
      validate_actor!(period)
      validate_recording_inputs!

      key = idempotency_key || "liability-settlement:#{period.id}:#{SecureRandom.uuid}"
      existing = payment_for_idempotency_key(key, period)
      return existing if existing

      requested = decimal_amount(amount)
      entries = open_entries(period, authority:, category:)
      available = entries.sum { |entry| open_amount(entry) }.round(2)
      raise InvalidStateError, "No open liability remains for this recipient and category" unless available.positive?
      if requested > available
        raise InvalidStateError, "Payment exceeds the open liability of #{format('%.2f', available)}"
      end

      payment = PayrollLiabilityPayment.create!(
        company: period.company,
        pay_period: period,
        recorded_by: actor,
        payment_type: "settlement",
        authority:,
        category:,
        amount: requested,
        payment_date: Date.iso8601(payment_date.to_s),
        payment_method:,
        confirmation_number:,
        notes:,
        idempotency_key: key,
        recorded_at: Time.current,
        metadata: { "allocation_strategy" => "oldest_open_entry_first" }
      )
      create_allocations!(payment, entries, requested)
      payment.reload
    end
  rescue Date::Error
    raise InvalidStateError, "Payment date is invalid"
  end

  def reverse!
    PayPeriod.transaction do
      period = locked_period!(allow_voided: true)
      validate_actor!(period)
      source = PayrollLiabilityPayment.lock
        .includes(:allocations, :reversal_payment)
        .find_by!(id: source_payment.id, company_id: period.company_id, pay_period_id: period.id)
      raise InvalidStateError, "A reversal cannot be reversed" if source.reversal?
      return source.reversal_payment if source.reversal_payment
      raise InvalidStateError, "A reversal reason is required" if reason.blank?

      key = idempotency_key || "liability-settlement:#{period.id}:payment:#{source.id}:reversal"
      existing = payment_for_idempotency_key(key, period)
      return existing if existing

      reversal = PayrollLiabilityPayment.create!(
        company: period.company,
        pay_period: period,
        source_payment: source,
        recorded_by: actor,
        payment_type: "reversal",
        authority: source.authority,
        category: source.category,
        amount: -source.amount,
        payment_date: Date.current,
        payment_method: source.payment_method,
        confirmation_number: source.confirmation_number,
        reason:,
        idempotency_key: key,
        recorded_at: Time.current,
        metadata: { "reverses_payment_id" => source.id }
      )
      rows = source.allocations.map do |allocation|
        {
          payroll_liability_payment_id: reversal.id,
          payroll_liability_entry_id: allocation.payroll_liability_entry_id,
          company_id: allocation.company_id,
          amount: -allocation.amount,
          metadata: { "reverses_allocation_id" => allocation.id },
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      PayrollLiabilityAllocation.insert_all!(rows)
      reversal.reload
    end
  end

  private

  attr_reader :pay_period, :actor, :authority, :category, :amount, :payment_date,
    :payment_method, :confirmation_number, :notes, :reason, :idempotency_key,
    :source_payment

  def locked_period!(allow_voided: false)
    period = PayPeriod.lock("FOR UPDATE").find(pay_period.id)
    raise InvalidStateError, "Payments require a committed pay period" unless period.committed?
    if period.voided? && !allow_voided
      raise InvalidStateError, "Payments cannot be recorded for a voided pay period"
    end

    period
  end

  def validate_actor!(period)
    return if actor&.organization_id == period.company.organization_id && actor.can_access_company?(period.company_id)

    raise InvalidStateError, "User cannot record payments for this client"
  end

  def validate_recording_inputs!
    raise InvalidStateError, "Recipient is required" if authority.blank?
    raise InvalidStateError, "Liability category is invalid" unless category.in?(PayrollLiabilityEntry::CATEGORIES)
    raise InvalidStateError, "Payment method is invalid" unless payment_method.in?(PayrollLiabilityPayment::PAYMENT_METHODS)
    raise InvalidStateError, "Payment date is required" if payment_date.blank?
  end

  def decimal_amount(value)
    decimal = BigDecimal(value.to_s).round(2)
    raise InvalidStateError, "Payment amount must be greater than zero" unless decimal.positive?

    decimal
  rescue ArgumentError
    raise InvalidStateError, "Payment amount is invalid"
  end

  def open_entries(period, authority:, category:)
    PayrollLiabilityEntry
      .joins(:payroll_liability_posting)
      .where(company_id: period.company_id, category:, authority:)
      .where(payroll_liability_postings: { pay_period_id: period.id })
      .where.not(payroll_liability_postings: { posting_type: "reversal" })
      .where.not(payroll_liability_posting_id: reversed_posting_ids(period))
      .includes(:payroll_liability_allocations, :payroll_liability_posting)
      .order("payroll_liability_postings.liability_date ASC", "payroll_liability_entries.id ASC")
  end

  def payment_for_idempotency_key(key, period)
    existing = PayrollLiabilityPayment.find_by(company_id: period.company_id, idempotency_key: key)
    return unless existing
    return existing if existing.pay_period_id == period.id

    raise InvalidStateError, "Idempotency key has already been used for another payroll"
  end

  def reversed_posting_ids(period)
    period.payroll_liability_postings.where.not(source_posting_id: nil).pluck(:source_posting_id)
  end

  def open_amount(entry)
    allocated = entry.payroll_liability_allocations.sum { |allocation| allocation.amount.to_d }
    (entry.amount.to_d - allocated).round(2)
  end

  def create_allocations!(payment, entries, requested)
    remaining = requested
    rows = entries.filter_map do |entry|
      next if remaining.zero?

      available = open_amount(entry)
      next unless available.positive?

      allocated = [ available, remaining ].min.round(2)
      remaining -= allocated
      {
        payroll_liability_payment_id: payment.id,
        payroll_liability_entry_id: entry.id,
        company_id: payment.company_id,
        amount: allocated,
        metadata: {},
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    raise InvalidStateError, "Unable to allocate the full payment" unless remaining.zero?

    PayrollLiabilityAllocation.insert_all!(rows)
  end
end
