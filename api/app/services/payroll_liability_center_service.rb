# frozen_string_literal: true

class PayrollLiabilityCenterService
  def initialize(company:)
    @company = company
  end

  def call
    entries = active_entries.includes(
      payroll_liability_check_allocations: :non_employee_check,
      payroll_liability_posting: :pay_period
    ).to_a
    due_dates = company.payroll_liability_obligation_due_dates.index_by do |record|
      [ record.pay_period_id, record.authority ]
    end
    obligations = entries.group_by do |entry|
      [ entry.payroll_liability_posting.pay_period_id, entry.authority ]
    end.filter_map do |(pay_period_id, authority), group|
      obligation_json(pay_period_id, authority, group, due_dates[[ pay_period_id, authority ]])
    end.sort_by { |row| [ row[:due_date]&.iso8601 || "9999-12-31", row[:liability_date].iso8601, row[:authority] ] }

    payments = liability_payments.includes(:paid_by, :created_by, :payroll_liability_check_allocations)
      .order(Arel.sql("COALESCE(payment_date, DATE(non_employee_checks.created_at)) DESC"), created_at: :desc)
      .map { |payment| payment_json(payment) }

    {
      company_id: company.id,
      as_of: Date.current,
      totals: totals(obligations),
      obligations:,
      payments:
    }
  end

  private

  attr_reader :company

  def active_entries
    reversed_source_ids = PayrollLiabilityPosting.reversals.select(:source_posting_id)
    company.payroll_liability_entries.joins(:payroll_liability_posting)
      .merge(PayrollLiabilityPosting.source_postings.where.not(id: reversed_source_ids))
  end

  def liability_payments
    NonEmployeeCheck.where(company_id: company.id)
      .where(id: PayrollLiabilityCheckAllocation.select(:non_employee_check_id))
  end

  def obligation_json(pay_period_id, authority, entries, due_date_record)
    period = entries.first.payroll_liability_posting.pay_period
    calculated = money(entries.sum { |entry| entry.amount.to_d })
    allocations = entries.flat_map(&:payroll_liability_check_allocations)
      .select { |allocation| !allocation.non_employee_check.voided? }
    prepared = money(allocations.sum { |allocation| allocation.amount.to_d })
    paid = money(allocations.select { |allocation| allocation.non_employee_check.paid_at.present? }
      .sum { |allocation| allocation.amount.to_d })
    return if calculated.zero? && prepared.zero? && paid.zero?

    outstanding = money(calculated - paid)
    unreserved = money(calculated - prepared)
    due_date = due_date_record&.due_date

    {
      key: "#{pay_period_id}:#{authority}",
      pay_period_id:,
      authority:,
      liability_date: entries.map { |entry| entry.payroll_liability_posting.liability_date }.max,
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      due_date:,
      calculated_amount: calculated.to_f,
      prepared_amount: prepared.to_f,
      paid_amount: paid.to_f,
      outstanding_amount: outstanding.to_f,
      unreserved_amount: unreserved.to_f,
      status: status_for(outstanding:, unreserved:, paid:, prepared:, due_date:),
      entry_ids: entries.map(&:id),
      categories: entries.group_by(&:category).map do |category, category_entries|
        { category:, amount: money(category_entries.sum { |entry| entry.amount.to_d }).to_f }
      end.reject { |row| row[:amount].zero? }.sort_by { |row| row[:category] }
    }
  end

  def status_for(outstanding:, unreserved:, paid:, prepared:, due_date:)
    return "credit" if outstanding.negative?
    return "paid" if outstanding.zero?
    return "overdue" if due_date.present? && due_date < Date.current
    return "partially_paid" if paid.positive?
    return "prepared" if unreserved <= 0
    return "partially_prepared" if prepared.positive?

    "unpaid"
  end

  def totals(obligations)
    calculated = money(obligations.sum { |row| row[:calculated_amount].to_d })
    prepared = money(obligations.sum { |row| row[:prepared_amount].to_d })
    paid = money(obligations.sum { |row| row[:paid_amount].to_d })
    {
      calculated_amount: calculated.to_f,
      prepared_amount: prepared.to_f,
      paid_amount: paid.to_f,
      outstanding_amount: money(calculated - paid).to_f,
      unreserved_amount: money(calculated - prepared).to_f,
      overdue_count: obligations.count { |row| row[:status] == "overdue" }
    }
  end

  def payment_json(payment)
    {
      id: payment.id,
      payable_to: payment.payable_to,
      amount: payment.amount.to_f,
      payment_method: payment.payment_method,
      payment_date: payment.payment_date,
      confirmation_number: payment.confirmation_number,
      check_number: payment.check_number,
      status: payment.check_status,
      printed_at: payment.printed_at,
      paid_at: payment.paid_at,
      paid_by_name: payment.paid_by&.name,
      created_by_name: payment.created_by&.name,
      voided: payment.voided?,
      void_reason: payment.void_reason,
      allocated_amount: payment.payroll_liability_check_allocations.sum { |allocation| allocation.amount.to_d }.round(2).to_f
    }
  end

  def money(value)
    value.to_d.round(2)
  end
end
