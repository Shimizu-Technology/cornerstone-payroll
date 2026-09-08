# frozen_string_literal: true

class PayrollParallelRunReviewService
  MONEY_FIELDS = %i[gross_pay net_pay taxes deductions].freeze

  def initialize(review:, pay_period:, source_totals:, notes:, actor:)
    @review = review
    @pay_period = pay_period
    @source_totals = source_totals.to_h.symbolize_keys
    @notes = notes.to_s.strip
    @actor = actor
  end

  def call!
    authorize!
    raise ArgumentError, "Approved go-live evidence is sealed" if review.approved?
    raise ArgumentError, "Choose a calculated or approved payroll" unless pay_period.status.in?(%w[calculated approved])
    raise ArgumentError, "This payroll belongs to another client" unless pay_period.company_id == review.company_id
    raise ArgumentError, "Explain what was compared" if notes.blank?

    source = normalized_source_totals
    cornerstone = cornerstone_totals
    differences = {
      "employee_count" => cornerstone.fetch(:employee_count) - source.fetch(:employee_count)
    }.merge(MONEY_FIELDS.to_h do |field|
      [ field.to_s, (cornerstone.fetch(field) - source.fetch(field)).round(2).to_s("F") ]
    end)
    passed = differences.fetch("employee_count").zero? && MONEY_FIELDS.all? do |field|
      BigDecimal(differences.fetch(field.to_s)).abs <= BigDecimal("0.01")
    end

    PayrollParallelRunReview.transaction do
      pay_period.lock!
      pay_period.update!(parallel_run: true)
      record = review.payroll_parallel_run_reviews.find_or_initialize_by(pay_period: pay_period)
      record.update!(
        company: review.company,
        recorded_by: actor,
        source_system: "quickbooks",
        result: passed ? "pass" : "fail",
        source_employee_count: source.fetch(:employee_count),
        cornerstone_employee_count: cornerstone.fetch(:employee_count),
        source_gross_pay: source.fetch(:gross_pay),
        source_net_pay: source.fetch(:net_pay),
        source_taxes: source.fetch(:taxes),
        source_deductions: source.fetch(:deductions),
        cornerstone_gross_pay: cornerstone.fetch(:gross_pay),
        cornerstone_net_pay: cornerstone.fetch(:net_pay),
        cornerstone_taxes: cornerstone.fetch(:taxes),
        cornerstone_deductions: cornerstone.fetch(:deductions),
        differences: differences,
        notes: notes
      )
      audit!(record)
      record
    end
  end

  private

  attr_reader :review, :pay_period, :source_totals, :notes, :actor

  def authorize!
    allowed = actor&.payroll_access_allowed? && actor.can_access_company?(review.company_id) &&
      StaffRolePolicy.allowed?(actor, :payroll_operations)
    raise ArgumentError, "Cornerstone payroll access is required" unless allowed
  end

  def normalized_source_totals
    employee_count = Integer(source_totals.fetch(:employee_count), exception: false)
    raise ArgumentError, "QuickBooks employee count must be zero or greater" unless employee_count && employee_count >= 0

    values = { employee_count: employee_count }
    MONEY_FIELDS.each do |field|
      value = BigDecimal(source_totals.fetch(field).to_s, exception: false)
      unless value && value >= 0
        raise ArgumentError, "QuickBooks #{field.to_s.tr('_', ' ')} must be zero or greater"
      end

      values[field] = value.round(2)
    end
    values
  rescue KeyError => e
    raise ArgumentError, "QuickBooks #{e.key.to_s.tr('_', ' ')} is required"
  end

  def cornerstone_totals
    items = pay_period.payroll_items.not_voided.to_a
    tax_total = items.sum do |item|
      item.withholding_tax.to_d + item.additional_withholding.to_d + item.social_security_tax.to_d +
        item.medicare_tax.to_d + item.additional_medicare_tax.to_d
    end.round(2)
    total_deductions = items.sum { |item| item.total_deductions.to_d }.round(2)
    {
      employee_count: items.size,
      gross_pay: items.sum { |item| item.gross_pay.to_d }.round(2),
      net_pay: items.sum { |item| item.net_pay.to_d }.round(2),
      taxes: tax_total,
      deductions: (total_deductions - tax_total).round(2)
    }
  end

  def audit!(record)
    AuditLog.record!(
      user: actor,
      organization_id: review.company.organization_id,
      company_id: review.company_id,
      action: "payroll_go_live#record_parallel_run",
      record_type: "payroll_parallel_run_reviews",
      record_id: record.id,
      subject_name: review.company.name,
      metadata: { pay_period_id: pay_period.id, result: record.result, differences: record.differences }
    )
  end
end
