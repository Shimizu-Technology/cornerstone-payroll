# frozen_string_literal: true

class EmployeeRetirementElectionChangeService
  class Error < StandardError; end

  def initialize(employee:, attributes:, actor:, source:, reason:)
    @employee = employee
    @attributes = attributes.to_h.symbolize_keys.slice(:effective_on, *EmployeeRetirementElection::SNAPSHOT_ATTRIBUTES)
    @actor = actor
    @source = source
    @reason = reason.to_s.strip
  end

  def call!
    raise Error, "Retirement elections are only available for W-2 employees" if employee.contractor?

    values = normalized_values
    prior = employee.employee_retirement_elections.recent_first.first
    return prior unless changed_from?(prior, values)

    raise Error, "Choose the first pay date for this retirement election" if values[:effective_on].blank?
    raise Error, "Explain why the retirement election is changing" if prior.present? && reason.blank?

    election = employee.employee_retirement_elections.create!(
      values.merge(
        company: employee.company,
        created_by: actor,
        source: source,
        reason: reason.presence || "Initial retirement election"
      )
    )
    sync_legacy_rates!(election) if election.effective_on <= Date.current
    election
  end

  private

  attr_reader :employee, :attributes, :actor, :source, :reason

  def normalized_values
    values = EmployeeRetirementElection::SNAPSHOT_ATTRIBUTES.index_with { |attribute| attributes[attribute] }
    values[:effective_on] = attributes[:effective_on]
    values[:plan_name] = values[:plan_name].to_s.strip.presence || "401(k)"
    values[:eligible] = true if values[:eligible].nil?
    values[:participating] = false if values[:participating].nil?
    values[:traditional_contribution_type] ||= "percentage"
    values[:roth_contribution_type] ||= "percentage"
    values[:traditional_rate] ||= 0
    values[:traditional_amount] ||= 0
    values[:roth_rate] ||= 0
    values[:roth_amount] ||= 0
    if values[:traditional_contribution_type] == "fixed"
      values[:traditional_rate] = 0
    else
      values[:traditional_amount] = 0
    end
    if values[:roth_contribution_type] == "fixed"
      values[:roth_rate] = 0
    else
      values[:roth_amount] = 0
    end
    values[:eligible_compensation] ||= "gross_wages"
    values[:catch_up_enabled] = false if values[:catch_up_enabled].nil?
    values[:limit_priority] ||= "proportional"
    values[:employer_match_mode] ||= "none"
    values[:employer_match_rate] ||= 0
    values[:employer_match_ytd_before_system] ||= 0
    values[:employer_match_destination] ||= "traditional"
    values[:true_up_policy] ||= "none"
    values
  end

  def changed_from?(prior, values)
    return true unless prior

    candidate = EmployeeRetirementElection.new(values)
    candidate_values = comparable_snapshot(candidate)
    existing_values = comparable_snapshot(prior)
    candidate_values != existing_values
  end

  def comparable_snapshot(record)
    [ :effective_on, *EmployeeRetirementElection::SNAPSHOT_ATTRIBUTES ].index_with do |attribute|
      comparable(record.public_send(attribute))
    end
  end

  def comparable(value)
    case value
    when BigDecimal, Numeric
      BigDecimal(value.to_s).to_s("F")
    when Date, Time, DateTime
      value.to_date.iso8601
    else
      value
    end
  end

  def sync_legacy_rates!(election)
    employee.update_columns(
      retirement_rate: election.traditional_contribution_type == "percentage" ? election.traditional_rate : 0,
      roth_retirement_rate: election.roth_contribution_type == "percentage" ? election.roth_rate : 0,
      employer_retirement_match_rate: election.employer_match_mode == "compensation_percentage" && election.employer_match_destination == "traditional" ? election.employer_match_rate : 0,
      employer_roth_match_rate: election.employer_match_mode == "compensation_percentage" && election.employer_match_destination == "roth" ? election.employer_match_rate : 0,
      updated_at: Time.current
    )
  end
end
