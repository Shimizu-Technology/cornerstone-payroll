# frozen_string_literal: true

class EmployeePayStatements
  LIST_ASSOCIATIONS = %i[pay_period check_events direct_deposit_payment_confirmation time_tracking_entry_allocations].freeze

  def initialize(company:, employee:)
    @company_id = company.id
    @employee = employee
  end

  # AIRE reads all years by default. When paging, filter out roster rows in SQL
  # before applying the limit so each page contains only statements.
  def list(year: nil, page: 1, page_size: nil)
    scope = statement_scope
      .order("pay_periods.pay_date DESC, pay_periods.id DESC, payroll_items.id DESC")
    scope = scope.where(pay_periods: { pay_date: Date.new(year)..Date.new(year, 12, 31) }) if year
    if page_size.nil?
      return scope.includes(*LIST_ASSOCIATIONS, :payroll_item_earnings, :payroll_item_deductions, :payroll_item_field_entries)
        .select { |item| statement?(item) }
    end

    unless [ page, page_size ].all? { |value| value.is_a?(Integer) && value.positive? }
      raise ArgumentError, "page and page_size must be positive integers"
    end

    scope.where(statement_condition).limit(page_size).offset((page - 1) * page_size).preload(*LIST_ASSOCIATIONS).to_a
  end

  def find(id)
    listed = statement_scope.find_by(id: id)
    return unless listed && statement?(listed)

    # Use the staff stub's preload so detail rows print and serialize in the same order.
    employee_items.includes(:payroll_item_earnings, :payroll_item_field_entries, :time_tracking_entry_allocations,
      { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company }).find(listed.id)
  end

  private

  def employee_items
    @employee.payroll_items.where(company_id: @company_id)
  end

  def statement_scope
    employee_items.reportable.joins(:pay_period)
      .where(pay_periods: { company_id: @company_id, status: "committed" })
  end

  # Retain voided and reversed checks in history alongside any replacement.
  def statement?(item)
    EarningsStatementEligibility.printable?(item) ||
      (!item.payroll_included? && (item.gross_pay.to_d.nonzero? || item.net_pay.to_d.nonzero? || item.check_number.present?))
  end

  def statement_condition
    items = PayrollItem.arel_table
    periods = PayPeriod.arel_table
    included = items[:payroll_reversed_at].eq(nil).and(periods[:correction_status].not_eq("voided").or(periods[:correction_status].eq(nil)))
    # Include Unicode whitespace even when PostgreSQL uses an ASCII locale.
    present_number = "[^[:space:]\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]"
    check_number = Arel::Nodes::Regexp.new(items[:check_number], Arel::Nodes.build_quoted(present_number), true)
    saved_pay = items[:gross_pay].not_eq(0).or(items[:net_pay].not_eq(0))
    other_fields = EarningsStatementEligibility::FINANCIAL_FIELDS - %i[gross_pay net_pay]
    financial_activity = other_fields.map { |field| items[field].not_eq(0) }.reduce(:or)
    row_activity = [
      PayrollItemEarning.all, PayrollItemDeduction.all, PayrollItemFieldEntry.active
    ].map { |scope| nonzero_rows(scope, items) }.reduce(:or)

    check_number.or(saved_pay).or(included.and(financial_activity.or(row_activity)))
  end

  def nonzero_rows(scope, items)
    rows = scope.klass.arel_table
    scope.where(rows[:payroll_item_id].eq(items[:id])).where.not(amount: 0).arel.exists
  end
end
