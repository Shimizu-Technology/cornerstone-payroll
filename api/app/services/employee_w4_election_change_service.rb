# frozen_string_literal: true

class EmployeeW4ElectionChangeService
  class Error < StandardError; end

  def initialize(employee:, attributes:, actor:, source:, reason:, election_received: false)
    @employee = employee
    @attributes = attributes.to_h.symbolize_keys.slice(*EmployeeW4Election::PROFILE_ATTRIBUTES)
    @attributes[:w4_source_reference] = @attributes[:w4_source_reference].to_s.strip.presence if @attributes.key?(:w4_source_reference)
    @election_received = ActiveModel::Type::Boolean.new.cast(election_received)
    @actor = actor
    @source = source
    @reason = reason.to_s.strip
  end

  def call!
    return if employee.contractor? || attributes.empty?

    # Never manufacture an initial election for an intake exception lacking a dated election.
    if employee.intake_exception.present? && employee.employee_w4_elections.none? && attributes[:w4_effective_on].blank? && employee.w4_effective_on.blank?
      return
    end
    values = complete_values
    prior = employee.employee_w4_elections.recent_first.first
    changed = changed_from?(prior, values)
    replacing_default = prior&.source == "default_withholding" && source != "default_withholding"
    return prior unless changed || (replacing_default && election_received)

    validate_default_replacement!(prior: prior, values: values) if replacing_default

    raise Error, "W-4 effective date is required when withholding elections change" if values[:effective_on].blank?
    if prior.present? && reason.blank?
      raise Error, "Explain why the W-4 election is changing"
    end

    election = employee.employee_w4_elections.create!(
      values.merge(
        company: employee.company,
        created_by: actor,
        source: source,
        reason: reason.presence || "Initial W-4 election"
      )
    )
    sync_employee_cache!
    election
  rescue Date::Error
    raise Error, "Provide a valid received election signed date"
  end

  def validate_default_replacement!(prior: employee.employee_w4_elections.recent_first.first, values: complete_values)
    return unless prior&.source == "default_withholding" && source != "default_withholding"
    return unless changed_from?(prior, values) || election_received

    raise Error, "Explicitly record receipt of the employee withholding election" unless election_received
    source_reference = attributes[:w4_source_reference].to_s.strip
    evidence = attributes[:w4_signed_on].present? ||
      (source_reference.present? && source_reference != prior.w4_source_reference)
    Date.iso8601(attributes[:w4_signed_on].to_s) if attributes[:w4_signed_on].present?
    unless attributes[:w4_effective_on].present? && evidence
      raise Error, "Provide the received election effective date and signed date or source reference"
    end
  rescue Date::Error
    raise Error, "Provide a valid received election signed date"
  end

  private

  attr_reader :employee, :attributes, :actor, :source, :reason, :election_received

  def complete_values
    baseline = employee.employee_w4_elections.recent_first.first&.profile_attributes ||
      EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
    profile = baseline.merge(attributes)
    if profile[:w4_effective_on].blank? && employee.employee_w4_elections.none?
      profile[:w4_effective_on] = employee.hire_date || Date.current
    end

    EmployeeW4Election::SNAPSHOT_ATTRIBUTES.index_with { |attribute| profile[attribute] }
      .merge(effective_on: profile[:w4_effective_on])
  end

  def changed_from?(prior, values)
    return true unless prior

    # Compare through Active Record's type casting. Controller payloads arrive as
    # strings, while persisted elections expose dates, decimals, integers, and
    # booleans. Comparing the raw payload would append a duplicate election when
    # an unrelated employee field was edited.
    candidate_record = EmployeeW4Election.new(values)
    candidate = EmployeeW4Election::SNAPSHOT_ATTRIBUTES.index_with do |attribute|
      comparable(candidate_record.public_send(attribute))
    end.merge(effective_on: comparable(candidate_record.effective_on))
    existing = EmployeeW4Election::SNAPSHOT_ATTRIBUTES.index_with { |attribute| comparable(prior.public_send(attribute)) }
      .merge(effective_on: comparable(prior.effective_on))
    candidate != existing
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

  def sync_employee_cache!
    latest = employee.employee_w4_elections.reload.recent_first.first
    changes = latest.profile_attributes.each_with_object({}) do |(attribute, value), updates|
      updates[attribute] = value if comparable(employee.public_send(attribute)) != comparable(value)
    end
    changes[:intake_payroll_confirmed_at] = nil if employee.intake_exception.present? && changes.present?
    employee.update_columns(changes.merge(updated_at: Time.current)) if changes.present?
  end
end
