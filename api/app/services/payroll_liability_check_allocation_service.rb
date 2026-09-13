# frozen_string_literal: true

# Reserves immutable payroll-liability journal entries for one outgoing
# payment. A reservation becomes a paid settlement only when the payment is
# explicitly marked paid; voiding or deleting a draft payment releases it.
class PayrollLiabilityCheckAllocationService
  class Error < StandardError; end

  def self.allocate!(...)
    new(...).allocate!
  end

  def initialize(non_employee_check:, entry_ids:)
    @non_employee_check = non_employee_check
    @entry_ids = Array(entry_ids).map { |id| Integer(id) }.uniq
  rescue ArgumentError, TypeError
    raise Error, "Liability selections are invalid"
  end

  def allocate!
    NonEmployeeCheck.transaction do
      payment = NonEmployeeCheck.lock.find(non_employee_check.id)
      raise Error, "A voided payment cannot reserve liabilities" if payment.voided?
      raise Error, "A paid payment cannot change its liability allocation" if payment.paid_at.present?
      raise Error, "Select at least one payroll liability" if entry_ids.empty?
      raise Error, "This payment already has liability allocations" if payment.payroll_liability_check_allocations.exists?

      lock_selected_pay_periods!(payment.company_id)
      entries = active_entries.includes(:payroll_liability_posting).lock
        .where(id: entry_ids, company_id: payment.company_id).order(:id).to_a
      raise Error, "One or more selected liabilities are unavailable" unless entries.length == entry_ids.length

      authorities = entries.map(&:authority).uniq
      raise Error, "One payment can cover only one recipient" unless authorities.one?
      validate_payment_recipient!(payment, authorities.first)

      available = available_amount(entries, payment.company_id)
      amount = payment.amount.to_d.round(2)
      raise Error, "Selected liabilities have no unreserved balance" unless available.positive?
      if amount > available
        raise Error, "Payment exceeds the selected unreserved liability of #{format('%.2f', available)}"
      end

      create_allocations!(payment, entries, amount)
      payment.reload
    end
  end

  private

  attr_reader :non_employee_check, :entry_ids

  def active_entries
    reversed_source_ids = PayrollLiabilityPosting.reversals.select(:source_posting_id)
    PayrollLiabilityEntry.joins(:payroll_liability_posting)
      .merge(PayrollLiabilityPosting.source_postings.where.not(id: reversed_source_ids))
  end

  def lock_selected_pay_periods!(company_id)
    pay_period_ids = PayrollLiabilityEntry.joins(:payroll_liability_posting)
      .where(id: entry_ids, company_id:)
      .distinct
      .pluck("payroll_liability_postings.pay_period_id")
    PayPeriod.where(id: pay_period_ids, company_id:).order(:id).lock.load
  end

  def available_amount(entries, company_id)
    liability = entries.sum { |entry| entry.amount.to_d }
    reserved = PayrollLiabilityCheckAllocation
      .joins(:non_employee_check)
      .where(company_id:, payroll_liability_entry_id: entries.map(&:id))
      .where(non_employee_checks: { voided: false })
      .sum(:amount).to_d
    (liability - reserved).round(2)
  end

  def validate_payment_recipient!(payment, authority)
    expected = authority == PayrollLiabilityPostingService::GUAM_DRT ? "Treasurer of Guam" : authority
    return if payment.payable_to.to_s.squish.casecmp?(expected.squish)

    raise Error, "Payment recipient must be #{expected} for the selected payroll liabilities"
  end

  def create_allocations!(payment, entries, requested)
    remaining = requested
    existing_by_entry = PayrollLiabilityCheckAllocation
      .joins(:non_employee_check)
      .where(company_id: payment.company_id, payroll_liability_entry_id: entries.map(&:id))
      .where(non_employee_checks: { voided: false })
      .group(:payroll_liability_entry_id)
      .sum(:amount)

    rows = entries.sort_by { |entry| [ entry.payroll_liability_posting.liability_date, entry.id ] }.filter_map do |entry|
      next if remaining.zero? || !entry.amount.to_d.positive?

      open_amount = (entry.amount.to_d - existing_by_entry.fetch(entry.id, 0).to_d).round(2)
      next unless open_amount.positive?

      allocated = [ open_amount, remaining ].min.round(2)
      remaining -= allocated
      {
        company_id: payment.company_id,
        non_employee_check_id: payment.id,
        payroll_liability_entry_id: entry.id,
        amount: allocated,
        metadata: { "allocation_strategy" => "oldest_selected_entry_first" },
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    raise Error, "Unable to allocate the full payment" unless remaining.zero?

    PayrollLiabilityCheckAllocation.insert_all!(rows)
  end
end
