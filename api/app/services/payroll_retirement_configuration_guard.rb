# frozen_string_literal: true

# A retirement election represented in two setup systems needs an explicit
# decision. Never infer that equal labels or amounts identify the same plan.
class PayrollRetirementConfigurationGuard
  RATE_LABELS = {
    retirement_rate: "Pre-Tax 401(k) percentage",
    roth_retirement_rate: "Roth 401(k) percentage",
    employer_retirement_match_rate: "Employer Pre-Tax Match percentage",
    employer_roth_match_rate: "Employer Roth Match percentage"
  }.freeze

  def initialize(employee:, payroll_item:)
    @employee = employee
    @payroll_item = payroll_item
  end

  def validate!
    configured_rates = configured_built_in_sources
    conflicts = recurring_deductions + payroll_fields
    messages = conflicts.filter_map do |source|
      overlap = configured_rates & source.fetch(:rates)
      next if overlap.empty?

      "#{overlap.map { |rate| RATE_LABELS.fetch(rate) }.join(' and ')} overlaps #{source.fetch(:label)}"
    end
    return if messages.empty?

    raise ArgumentError, "Retirement setup needs review: #{messages.uniq.join('; ')}. " \
      "Choose one setup for the same contribution, or identify a separate plan with its correct reporting group, then recalculate."
  end

  private

  def configured_built_in_sources
    election = @employee.retirement_election_on(@payroll_item.pay_period.pay_date)
    return RATE_LABELS.keys.select { |attribute| @employee.public_send(attribute).to_d.positive? } unless election
    return [] unless election.eligible? && election.participating?

    sources = []
    traditional_value = election.traditional_contribution_type == "fixed" ? election.traditional_amount : election.traditional_rate
    roth_value = election.roth_contribution_type == "fixed" ? election.roth_amount : election.roth_rate
    sources << :retirement_rate if traditional_value.to_d.positive?
    sources << :roth_retirement_rate if roth_value.to_d.positive?
    if election.employer_match_mode != "none" && election.employer_match_rate.to_d.positive?
      sources << (election.employer_match_destination == "roth" ? :employer_roth_match_rate : :employer_retirement_match_rate)
    end
    sources
  end

  def recurring_deductions
    @employee.employee_deductions.select(&:active?).filter_map do |assignment|
      type = assignment.deduction_type
      next unless type&.active? && assignment.amount.to_d.positive?

      source_for(
        label: "recurring deduction \"#{type.name}\"", name: type.name,
        category: type.sub_category, reporting_group: type.reporting_group,
        treatment: type.category
      )
    end
  end

  def payroll_fields
    # Explicit paycheck entries survive inactive/expired assignments in the
    # calculator. Inspect those actual entries, including a zero override, rather
    # than incorrectly resurrecting an employee default for the guard.
    explicit_entries = @payroll_item.payroll_item_field_entries.select { |entry| entry.source.in?(%w[manual import]) }
    overridden_ids = explicit_entries.map(&:payroll_field_definition_id)
    defaults = @payroll_item.active_payroll_field_assignments_for(@employee).filter_map do |assignment|
      field = assignment.payroll_field_definition
      next unless field&.active? && !overridden_ids.include?(field.id)
      configured_amount = if field.amount_type == "percentage"
        assignment.percentage.presence || field.default_percentage
      else
        assignment.amount.presence || field.default_amount
      end
      next unless configured_amount.to_d.positive?

      source_for(label: "payroll field \"#{field.name}\"", name: field.name,
        category: field.category, reporting_group: field.reporting_group, treatment: field.tax_treatment)
    end

    defaults + explicit_entries.filter_map do |entry|
      next unless entry.active? && entry.amount.to_d.positive?

      source_for(label: "paycheck field \"#{entry.label}\"", name: entry.label,
        category: entry.category,
        reporting_group: entry.reporting_group.presence || entry.payroll_field_definition&.reporting_group,
        treatment: entry.tax_treatment)
    end
  end

  def source_for(label:, name:, category:, reporting_group:, treatment:)
    return if reporting_group == PayrollReportingGroups::GROUP_RETIREMENT_OTHER
    return unless treatment.in?(%w[pre_tax post_tax employer_contribution pre_tax_deduction post_tax_deduction])

    group = PayrollReportingGroups.infer_retirement_group(
      label: name, category: category, explicit_group: reporting_group,
      tax_treatment: treatment, deduction_category: treatment
    )
    return unless group

    validate_tax_treatment!(label: label, group: group, treatment: treatment)

    rates = if treatment == "employer_contribution"
      case group
      when PayrollReportingGroups::GROUP_401K_PRE_TAX then [ :employer_retirement_match_rate ]
      when PayrollReportingGroups::GROUP_401K_AFTER_TAX then [ :employer_roth_match_rate ]
      else [ :employer_retirement_match_rate, :employer_roth_match_rate ]
      end
    elsif treatment.in?(%w[post_tax post_tax_deduction])
      [ :roth_retirement_rate ]
    else
      [ :retirement_rate ]
    end
    { label: label, rates: rates }
  end

  def validate_tax_treatment!(label:, group:, treatment:)
    return if treatment == "employer_contribution"

    incompatible = if group == PayrollReportingGroups::GROUP_401K_PRE_TAX
      treatment.in?(%w[post_tax post_tax_deduction])
    elsif group == PayrollReportingGroups::GROUP_401K_AFTER_TAX
      treatment.in?(%w[pre_tax pre_tax_deduction])
    end
    return unless incompatible

    tax_description = treatment.in?(%w[pre_tax pre_tax_deduction]) ? "before taxes" : "after taxes"
    raise ArgumentError, "Retirement setup needs review: #{label} is reported as #{PayrollReportingGroups.label(group)} " \
      "but deducts #{tax_description}. Make its tax treatment and reporting group agree with the employee's verified election, then recalculate."
  end
end
