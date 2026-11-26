# frozen_string_literal: true

# The earlier and current paychecks and the locked QuickBooks opening balance a
# statement's YTD adds up. Loaded once, with every component the statement
# readers need, so the earnings rows, the other YTD rows and the YTD totals
# count exactly the same population without querying it again.
class PayrollStatementYtdSources
  ITEM_COMPONENTS = [
    :payroll_item_earnings,
    { payroll_item_field_entries: :payroll_field_definition },
    { payroll_item_deductions: :deduction_type }
  ].freeze
  # Each printed YTD total and the payroll item amount it accumulates.
  TOTAL_FIELDS = {
    gross: :gross_pay, withholding_tax: :withholding_tax, social_security_tax: :social_security_tax,
    medicare_tax: :medicare_tax, additional_withholding: :additional_withholding, net: :net_pay
  }.freeze

  attr_reader :payroll_item

  def initialize(payroll_item)
    @payroll_item = payroll_item
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @company = payroll_item.company
  end

  def historical_balance
    return @historical_balance if defined?(@historical_balance)

    @historical_balance = HistoricalEmployeeYtdBalance
      .joins(:historical_ytd_bridge)
      .where(
        company_id: @company.id,
        employee_id: @employee.id,
        tax_year: pay_date.year,
        historical_ytd_bridges: { status: "applied" }
      )
      .where("historical_employee_ytd_balances.through_pay_date <= ?", pay_date)
      .order(
        through_pay_date: :desc,
        "historical_ytd_bridges.applied_at" => :desc,
        "historical_ytd_bridges.id" => :desc,
        id: :desc
      )
      .first
  end

  # Historical opening balances carry only combined Medicare.
  def additional_medicare_ytd
    return if historical_balance

    @additional_medicare_ytd ||= items.sum(0.to_d) { |item| item.additional_medicare_tax.to_d }
  end

  # Every YTD total a statement prints: the dated opening balance plus the
  # same earlier and current paychecks the YTD rows add up, so the totals and
  # rows always agree.
  def totals
    @totals ||= begin
      opening = historical_balance&.ytd_aggregate_totals || {}
      TOTAL_FIELDS.transform_values do |field|
        (opening.fetch(field, 0).to_d + items.sum(0.to_d) { |item| item.public_send(field).to_d }).round(2)
      end
    end
  end

  # A native paycheck dated on or before the opening balance's through date
  # counts only once it is recorded as a payment distinct from the imported
  # ones (PayrollBridgeOverlap); a duplicate, or one still awaiting review,
  # stays out, as the balance is taken to hold it.
  def items
    @items ||= begin
      prior_periods = PayPeriod.reportable_for_company(@company)
        .where(pay_date: Date.new(pay_date.year, 1, 1)..pay_date)
        .where("pay_date < :pay_date OR (pay_date = :pay_date AND id < :period_id)", pay_date: pay_date, period_id: @pay_period.id)
      items = @employee.payroll_items.financially_reportable.reportable
        .where(company_id: @company.id, pay_period_id: prior_periods.select(:id))
      if historical_cutoff
        items = items.where("pay_periods.pay_date > ? OR payroll_items.id IN (?)", historical_cutoff, distinct_overlap_ids)
      end
      items = items.eager_load(:pay_period).order("pay_periods.pay_date", "pay_periods.id", :id).to_a
      # Every period here is this company's.
      items.each { |item| item.pay_period.association(:company).target = @company }

      if payroll_item.payroll_included? && @pay_period.correction_status.in?([ nil, "correction" ]) &&
          (historical_cutoff.nil? || pay_date > historical_cutoff || distinct_overlap_ids.exists?(payroll_item_id: payroll_item.id))
        items << payroll_item
      end
      preload_components(items.reject { |item| item.equal?(payroll_item) })
      items
    end
  end

  def historical_cutoff
    historical_balance&.through_pay_date
  end

  private

  def distinct_overlap_ids
    PayrollBridgeOverlap.distinct_item_ids(company_id: @company.id, batch_id: historical_balance.historical_ytd_bridge.historical_import_batch_id)
  end

  # The saved paycheck's own components load in the same batch queries. A
  # draft or preview may hold unsaved components in memory; those stay as built.
  def preload_components(prior_items)
    records = prior_items.dup
    records << payroll_item if payroll_item.persisted? && ITEM_COMPONENTS.all? do |component|
      name = component.is_a?(Hash) ? component.keys.first : component
      association = payroll_item.association(name)
      !association.loaded? && association.target.empty?
    end
    ActiveRecord::Associations::Preloader.new(records: records, associations: ITEM_COMPONENTS).call if records.any?
  end

  def pay_date
    @pay_period.pay_date || Date.current
  end
end
