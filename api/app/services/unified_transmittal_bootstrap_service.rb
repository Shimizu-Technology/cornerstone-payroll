# frozen_string_literal: true

class UnifiedTransmittalBootstrapService
  REPORTS = [
    [ "payroll_register", "Payroll Register", "Complete payroll detail for the pay period" ],
    [ "payroll_summary", "Payroll Summary by Employee", "Employee earnings, deductions, taxes, and net pay" ],
    [ "deductions", "Deductions & Contributions", "Employee deductions and employer contributions" ],
    [ "paycheck_history", "Paycheck History", "Check numbers, amounts, and payment status" ],
    [ "retirement", "Retirement Plans Report", "Retirement contribution summary" ],
    [ "check_signoff", "Check Sign-Off Sheet", "Employee check pickup and acknowledgment sheet" ]
  ].freeze

  def initialize(pay_period:, actor:)
    @pay_period = pay_period
    @actor = actor
  end

  def call
    PayPeriod.transaction do
      locked_period = PayPeriod.lock.find(pay_period.id)
      transmittal = GeneralTransmittal.lock.find_by(pay_period_id: locked_period.id)
      transmittal ||= create_transmittal!(locked_period)
      raise ArgumentError, "Pay period belongs to a different client" unless transmittal.company_id == locked_period.company_id

      append_missing_sources!(transmittal, source_specs(locked_period))
      transmittal.reload
    end
  rescue ActiveRecord::RecordNotUnique
    GeneralTransmittal.find_by!(pay_period_id: pay_period.id, company_id: pay_period.company_id)
  end

  private

  attr_reader :pay_period, :actor

  def create_transmittal!(period)
    legacy = period.transmittal
    GeneralTransmittal.create!(
      company: period.company,
      pay_period: period,
      source_kind: "pay_period",
      title: "Payroll transmittal — #{period.start_date.strftime('%b %-d')}–#{period.end_date.strftime('%b %-d, %Y')}",
      transmittal_date: legacy&.transmittal_date || period.pay_date || Date.current,
      preparer_name: legacy&.preparer_name.presence || actor&.name,
      recipient_name: period.company.name,
      notes: normalized_legacy_notes(legacy),
      created_by: actor,
      updated_by: actor,
      status: "draft"
    )
  end

  def normalized_legacy_notes(legacy)
    notes = Array(legacy&.notes).map(&:to_s).map(&:strip).reject(&:blank?)
    notes << "Started from the saved pay-period transmittal." if legacy.present?
    notes.uniq
  end

  def append_missing_sources!(transmittal, specs)
    existing = transmittal.items.where.not(source_key: nil).pluck(:source_key).to_set
    next_position = transmittal.items.maximum(:position).to_i
    next_position += 1 if transmittal.items.exists?

    specs.each do |attributes|
      next if existing.include?(attributes.fetch(:source_key))

      transmittal.items.create!(attributes.merge(position: next_position))
      existing << attributes.fetch(:source_key)
      next_position += 1
    end
  end

  def source_specs(period)
    payroll_items = period.payroll_items.not_voided.includes(:employee).order(:id).to_a
    non_employee_checks = period.non_employee_checks.active.order(:id).to_a

    payroll_check_specs(payroll_items) +
      non_employee_check_specs(non_employee_checks) +
      report_specs(period) +
      obligation_specs(payroll_items, period)
  end

  def payroll_check_specs(items)
    items.filter_map do |item|
      next unless item.net_pay.to_d.positive?

      {
        source_key: "payroll_item:#{item.id}",
        source_type: "PayrollItem",
        source_id: item.id,
        item_type: "check",
        title: "Employee check — #{item.employee.full_name}",
        payable_to: item.employee.full_name,
        check_number: item.check_number,
        amount: item.net_pay,
        details: [ item.check_number.present? ? "Check ##{item.check_number}" : "Check number not assigned" ],
        included: true,
        metadata: { source_category: "employee_check" }
      }
    end
  end

  def non_employee_check_specs(checks)
    checks.map do |check|
      {
        source_key: "non_employee_check:#{check.id}",
        source_type: "NonEmployeeCheck",
        source_id: check.id,
        item_type: "check",
        title: "Non-employee check — #{check.payable_to}",
        payable_to: check.payable_to,
        check_number: check.check_number,
        amount: check.amount,
        details: [ check.memo.presence || check.description.presence || check.check_type.to_s.titleize ].compact,
        included: true,
        metadata: { source_category: "non_employee_check", check_type: check.check_type }
      }
    end
  end

  def report_specs(period)
    REPORTS.map do |key, title, description|
      {
        source_key: "report:#{key}",
        item_type: "report",
        title: title,
        details: [ description ],
        included: true,
        metadata: { source_category: "report", report_key: key, pay_period_id: period.id }
      }
    end
  end

  def obligation_specs(items, period)
    totals = {
      income_tax: items.sum { |item| item.total_income_tax_withheld.to_d },
      employee_social_security: items.sum { |item| item.social_security_tax.to_d },
      employer_social_security: items.sum { |item| item.social_security_tax.to_d },
      employee_medicare: items.sum { |item| item.medicare_tax.to_d },
      employer_medicare: items.sum { |item| item.medicare_tax.to_d }
    }

    labels = {
      income_tax: "Guam income tax withholding",
      employee_social_security: "Social Security — employee",
      employer_social_security: "Social Security — employer",
      employee_medicare: "Medicare — employee",
      employer_medicare: "Medicare — employer"
    }

    totals.map do |key, amount|
      {
        source_key: "tax_obligation:#{key}",
        item_type: "tax_obligation",
        title: labels.fetch(key),
        payable_to: key == :income_tax ? "Guam Department of Revenue and Taxation" : "U.S. Treasury",
        amount: amount,
        details: [ "Calculated obligation for pay date #{period.pay_date&.strftime('%m/%d/%Y') || 'not set'}", "Payment is not recorded by this transmittal." ],
        included: amount.positive?,
        metadata: { source_category: "tax_obligation", obligation_key: key, calculated_only: true }
      }
    end
  end
end
