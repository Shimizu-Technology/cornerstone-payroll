# frozen_string_literal: true

class CheckPrintQueueService
  def initialize(pay_period:)
    @pay_period = pay_period
  end

  def call
    raise ArgumentError, "Checks are only available for committed pay periods" unless pay_period.committed?

    employee_items = pay_period.payroll_items
      .includes(:employee)
      .where.not(check_number: [ nil, "" ])
      .to_a
      .map { |item| queue_item_for_payroll_item(item) }

    non_employee_items = pay_period.non_employee_checks
      .to_a
      .map { |check| queue_item_for_non_employee_check(check) }

    items = (employee_items + non_employee_items).sort_by { |item| check_number_sort_key(item.fetch(:check_number), item.fetch(:key)) }

    {
      items: items,
      meta: {
        total: items.size,
        eligible: items.count { |item| item.fetch(:eligible) },
        unprinted: items.count { |item| item.fetch(:eligible) && item.fetch(:status) == "unprinted" },
        printed: items.count { |item| item.fetch(:eligible) && item.fetch(:status) == "printed" },
        voided: items.count { |item| item.fetch(:status) == "voided" },
        check_stock_type: pay_period.company.check_stock_type,
        slot_count: pay_period.company.first_hawaiian_4up_checks? ? FirstHawaiianFourUpCheckGenerator::SLOT_COUNT : 1
      }
    }
  end

  private

  attr_reader :pay_period

  def queue_item_for_payroll_item(item)
    eligible = !item.voided? && item.net_pay.to_d.positive?
    {
      key: "payroll_item:#{item.id}",
      source_type: "payroll_item",
      source_id: item.id,
      check_number: item.check_number.to_s,
      payee: item.employee.full_name,
      amount: item.net_pay.to_d.to_f,
      kind: "employee",
      kind_label: "Employee check",
      status: item.check_status,
      print_count: item.check_print_count.to_i,
      printed_at: item.check_printed_at&.iso8601,
      eligible: eligible,
      disabled_reason: payroll_item_disabled_reason(item)
    }
  end

  def queue_item_for_non_employee_check(check)
    eligible = !check.voided? && check.check_number.present?
    {
      key: "non_employee_check:#{check.id}",
      source_type: "non_employee_check",
      source_id: check.id,
      check_number: check.check_number.to_s,
      payee: check.payable_to,
      amount: check.amount.to_d.to_f,
      kind: "non_employee",
      kind_label: "Non-employee check",
      status: check.check_status,
      print_count: check.print_count.to_i,
      printed_at: check.printed_at&.iso8601,
      eligible: eligible,
      disabled_reason: non_employee_check_disabled_reason(check)
    }
  end

  def non_employee_check_disabled_reason(check)
    return "Voided checks cannot be printed" if check.voided?
    return "Assign a check number before printing" if check.check_number.blank?

    nil
  end

  def payroll_item_disabled_reason(item)
    return "Voided checks cannot be printed" if item.voided?
    return "Checks with no net pay cannot be printed" unless item.net_pay.to_d.positive?

    nil
  end

  def check_number_sort_key(check_number, fallback)
    value = check_number.to_s
    if value.match?(/\A\d+\z/)
      [ 0, value.to_i, value, fallback ]
    else
      [ 1, 0, value.downcase, fallback ]
    end
  end
end
