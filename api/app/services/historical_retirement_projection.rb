# frozen_string_literal: true

require "digest"

# An evidence-only projection of the applied bridge. Never changes imported
# amounts, source tax buckets, wage totals or the paid paycheck snapshot.
class HistoricalRetirementProjection
  BUCKETS = %w[pretax_deduction_breakdown after_tax_deduction_breakdown].freeze
  GROUP_KEYS = PayrollRetirementTotals::GROUP_KEYS.merge(
    PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX => :non_roth_after_tax
  ).freeze
  REVIEW_MESSAGE = "Review the applied historical 401(k) classification in Retirement year evidence before calculating payroll. Historical wage/FIT filing corrections require a separate review."

  def initialize(employee:, tax_year:, balance: nil, review: nil)
    @employee = employee
    @tax_year = tax_year.to_i
    @balance = balance || employee.send(:applied_historical_ytd_balance, @tax_year)
    @review = review.nil? ? employee.retirement_year_input_for(@tax_year)&.historical_retirement_review.to_h : review
  end

  def source
    return unless balance && candidates.any?

    { tax_year: tax_year, balance_digest: balance_digest, historical_balance_id: balance.id,
      classifications: candidates }
  end

  def balance_digest
    # Database identities deliberately excluded so an exact archive clone has
    # the same digest. All immutable business fields participate in the seal.
    attributes = balance.attributes.except("id", "company_id", "employee_id", "historical_ytd_bridge_id", "created_at", "updated_at")
    Digest::SHA256.hexdigest(JSON.generate(stable_value(attributes)))
  end

  def validate_review!
    raise ArgumentError, REVIEW_MESSAGE unless balance && balance.employee_id == employee.id &&
      balance.company_id == employee.company_id && balance.tax_year == tax_year &&
      balance.historical_ytd_bridge.applied? && balance.historical_ytd_bridge.company_id == employee.company_id
    raise ArgumentError, "#{REVIEW_MESSAGE} The retained source digest has changed." unless review.is_a?(Hash) &&
      review["balance_digest"] == balance_digest

    rows = review["classifications"]
    raise ArgumentError, "#{REVIEW_MESSAGE} Classify every retained candidate exactly once." unless rows.is_a?(Array) &&
      rows.all? { |row| row.is_a?(Hash) && GROUP_KEYS.key?(row["reporting_group"]) } &&
      rows.map { |row| row.slice("source_bucket", "source_label", "amount") }.sort_by { |row| row.values.join("\0") } ==
        candidates.map(&:stringify_keys).sort_by { |row| row.values.join("\0") }
    reconciled_totals(rows)
    true
  end

  def totals(strict: false)
    if !balance
      raise ArgumentError, REVIEW_MESSAGE if strict && review.present?
      return zero_totals
    end
    if candidates.any? || review.present?
      validate_review!
      reconciled_totals(review.fetch("classifications"))
    else
      canonical_totals.merge(non_roth_after_tax: source_rows.sum(0.to_d) { |row| canonical_source_group(row) == PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX ? decimal!(row[:amount]) : 0.to_d })
    end
  rescue ArgumentError
    raise if strict

    canonical_totals
  end

  def reviewed_classifications
    validate_review!
    review.fetch("classifications")
  rescue ArgumentError
    []
  end

  def employer_additions
    return 0.to_d unless balance

    balance.source_breakdown.to_h.fetch("employer_contribution_breakdown", {}).to_h.sum(0.to_d) do |label, amount|
      group = PayrollReportingGroups.infer_retirement_group(label: label, deduction_category: "employer_contribution")
      # A known 401(k) employer contribution counts under 415(c) regardless
      # of employee Traditional/Roth destination. No destination is inferred.
      label.match?(/401\s*\(?k\)?/i) || GROUP_KEYS.key?(group) ? decimal!(amount) : 0.to_d
    end.round(2)
  end

  private

  attr_reader :employee, :tax_year, :balance, :review

  def candidates
    @candidates ||= source_rows.filter_map do |row|
      next if canonical_source_group(row)
      next unless row[:source_label].match?(/401\s*\(?k\)?/i)
      next if decimal!(row[:amount]).zero?

      row
    end
  end

  def source_rows
    BUCKETS.flat_map do |bucket|
      balance.source_breakdown.to_h.fetch(bucket, {}).to_h.map do |label, amount|
        { source_bucket: bucket, source_label: label, amount: decimal!(amount).to_s("F") }
      end
    end
  end

  def canonical_source_group(row)
    label = row[:source_label]
    if row[:source_bucket] == "pretax_deduction_breakdown" && label.match?(QuickbooksHistory::YtdBridgePlan::RETIREMENT_PRE_TAX)
      PayrollReportingGroups::GROUP_401K_PRE_TAX
    elsif row[:source_bucket] == "after_tax_deduction_breakdown" && label.match?(QuickbooksHistory::YtdBridgePlan::RETIREMENT_ROTH)
      PayrollReportingGroups::GROUP_401K_AFTER_TAX
    elsif PayrollReportingGroups.infer_retirement_group(label: label) == PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX
      PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX
    end
  end

  def reconciled_totals(rows)
    known = zero_totals
    source_rows.each do |row|
      key = GROUP_KEYS[canonical_source_group(row)]
      known[key] += decimal!(row[:amount]) if key
    end
    classified = zero_totals
    rows.each do |row|
      classified[GROUP_KEYS.fetch(row.fetch("reporting_group"))] += decimal!(row.fetch("amount"))
    end
    totals = known.merge(non_roth_after_tax: known[:non_roth_after_tax] + classified[:non_roth_after_tax])
    %i[retirement roth_retirement].each do |key|
      residual = canonical_totals[key] - known[key]
      unless residual.zero? || (residual.positive? && residual == classified[key])
        raise ArgumentError, "#{REVIEW_MESSAGE} Canonical #{key} does not reconcile with the retained source amounts."
      end
      totals[key] = known[key] + classified[key]
    end
    totals
  end

  def canonical_totals
    { retirement: balance.retirement.to_d, roth_retirement: balance.roth_retirement.to_d, non_roth_after_tax: 0.to_d }
  end

  def zero_totals
    { retirement: 0.to_d, roth_retirement: 0.to_d, non_roth_after_tax: 0.to_d }
  end

  def decimal!(value)
    amount = BigDecimal(value.to_s, exception: false)
    raise ArgumentError, "#{REVIEW_MESSAGE} Invalid retained source amount." unless amount&.finite? && amount >= 0 && amount == amount.round(2)

    amount
  end

  def stable_value(value)
    case value
    when Hash then value.sort.to_h.transform_values { |child| stable_value(child) }
    when Array then value.map { |child| stable_value(child) }
    when BigDecimal then value.to_s("F")
    when Date, Time, ActiveSupport::TimeWithZone then value.iso8601
    else value
    end
  end
end
