# frozen_string_literal: true

class EmployeeReadinessEvaluator
  Item = Data.define(:key, :label, :complete, :applicable, :missing_label, :metadata) do
    def missing?
      applicable && !complete
    end

    def as_json(*)
      {
        key: key,
        label: label,
        complete: complete,
        applicable: applicable,
        missing_label: missing_label,
        metadata: metadata
      }
    end
  end

  Result = Data.define(
    :employee_id,
    :rates_on,
    :w4_on,
    :readiness_gate_enforced,
    :rehire_or_grandfathered,
    :items,
    :direct_deposit_missing_bank_details
  ) do
    def missing_items
      items.select(&:missing?)
    end

    def missing_keys
      missing_items.map(&:key)
    end

    def ready?
      missing_items.empty?
    end

    def incomplete?
      !ready?
    end

    def hard_blocked?
      readiness_gate_enforced && incomplete?
    end

    def direct_deposit_missing_bank_details?
      direct_deposit_missing_bank_details
    end

    def status
      return "ready" if ready?

      readiness_gate_enforced ? "incomplete" : "missing_items"
    end

    def reason
      labels = missing_items.filter_map(&:missing_label)
      return nil if labels.empty?

      summary = case labels.length
      when 1
        labels.first
      when 2
        "#{labels[0]} and #{labels[1]}"
      else
        remaining = labels.length - 2
        "#{labels[0]}, #{labels[1]}, and #{remaining} more #{remaining == 1 ? 'item' : 'items'}"
      end

      "Can't be paid yet: #{summary}."
    end

    def as_json(*)
      {
        employee_id: employee_id,
        status: status,
        ready: ready?,
        incomplete: incomplete?,
        hard_blocked: hard_blocked?,
        readiness_gate_enforced: readiness_gate_enforced,
        rehire_or_grandfathered: rehire_or_grandfathered,
        rates_on: rates_on.iso8601,
        w4_on: w4_on.iso8601,
        missing_keys: missing_keys,
        reason: reason,
        direct_deposit_missing_bank_details: direct_deposit_missing_bank_details,
        items: items.map(&:as_json)
      }
    end
  end

  class << self
    def evaluate(employee, rates_on: nil, w4_on: nil)
      resolved_rates_on, resolved_w4_on = resolve_dates(employee, rates_on: rates_on, w4_on: w4_on)
      new(employee: employee, rates_on: resolved_rates_on, w4_on: resolved_w4_on).evaluate
    end

    def evaluate_batch(employees, company:, rates_on: nil, w4_on: nil)
      rows = Array(employees)
      return {} if rows.empty?

      shared_dates =
        if rates_on.present? && w4_on.present?
          [ rates_on.to_date, w4_on.to_date ]
        elsif company.present?
          default_rates_on, default_w4_on = target_dates_for(company)
          [ (rates_on || default_rates_on).to_date, (w4_on || default_w4_on).to_date ]
        end

      rehired_ids = Set.new
      committed_payroll_ids = Set.new
      if company.present?
        enforced_ids = rows.select(&:readiness_gate_enforced?).filter_map(&:id)
        if enforced_ids.any?
          rehired_ids = EmployeeStatusEvent.where(
            company_id: company.id,
            employee_id: enforced_ids,
            event_type: "reactivated",
            previous_status: "terminated"
          ).distinct.pluck(:employee_id).to_set
        end

        remaining_ids = enforced_ids - rehired_ids.to_a
        if remaining_ids.any?
          committed_payroll_ids = PayrollItem.where(company_id: company.id, employee_id: remaining_ids)
            .joins(:pay_period)
            .financially_reportable
            .where(pay_periods: { status: "committed" })
            .distinct
            .pluck(:employee_id)
            .to_set
        end
      end

      dates_by_company_id = {}
      rows.each_with_object({}) do |employee, results|
        row_rates_on, row_w4_on = if shared_dates
          shared_dates
        elsif employee.company.present?
          default_rates_on, default_w4_on = dates_by_company_id[employee.company_id] ||= target_dates_for(employee.company)
          [ (rates_on || default_rates_on).to_date, (w4_on || default_w4_on).to_date ]
        else
          resolve_dates(employee, rates_on: rates_on, w4_on: w4_on)
        end

        results[employee.id] = new(
          employee: employee,
          rates_on: row_rates_on,
          w4_on: row_w4_on,
          rehired: company.present? ? rehired_ids.include?(employee.id) : nil,
          prior_committed_payroll: company.present? ? committed_payroll_ids.include?(employee.id) : nil
        ).evaluate
      end
    end

    def for_pay_period(employee, pay_period)
      evaluate(employee, rates_on: pay_period.end_date, w4_on: pay_period.pay_date)
    end

    def ready?(employee, rates_on: nil, w4_on: nil)
      evaluate(employee, rates_on: rates_on, w4_on: w4_on).ready?
    end

    def incomplete?(employee, rates_on: nil, w4_on: nil)
      evaluate(employee, rates_on: rates_on, w4_on: w4_on).incomplete?
    end

    def reason_for(employee, rates_on: nil, w4_on: nil)
      evaluate(employee, rates_on: rates_on, w4_on: w4_on).reason
    end

    def tax_id_complete?(employee)
      if employee.business_contractor?
        employee.form_1099_tin&.dig(:type) == "EIN"
      elsif employee.contractor?
        employee.form_1099_tin.present?
      else
        employee.valid_filing_ssn?
      end
    end

    def target_dates_for(company)
      period = PayPeriod.where(
        company_id: company.id,
        status: %w[draft calculated],
        cycle: "regular",
        run_purpose: "regular",
        correction_status: nil,
        test_workspace_role: nil,
        parallel_run: false
      ).order(pay_date: :asc, id: :asc).first

      if period
        [ period.end_date, period.pay_date ]
      else
        today = PayrollBusinessClock.today
        [ today, today ]
      end
    end

    private

    def resolve_dates(employee, rates_on:, w4_on:)
      if rates_on.present? && w4_on.present?
        [ rates_on.to_date, w4_on.to_date ]
      elsif employee.company.present?
        default_rates_on, default_w4_on = target_dates_for(employee.company)
        [ (rates_on || default_rates_on).to_date, (w4_on || default_w4_on).to_date ]
      else
        today = PayrollBusinessClock.today
        [ (rates_on || today).to_date, (w4_on || today).to_date ]
      end
    end
  end

  def initialize(employee:, rates_on:, w4_on:, rehired: nil, prior_committed_payroll: nil)
    @employee = employee
    @rates_on = rates_on.to_date
    @w4_on = w4_on.to_date
    @today = PayrollBusinessClock.today
    @preloaded_rehired = rehired
    @preloaded_prior_committed_payroll = prior_committed_payroll
  end

  def evaluate
    items = [
      evaluate_legal_name,
      evaluate_tax_id,
      evaluate_date_of_birth,
      evaluate_hire_date,
      evaluate_home_address,
      evaluate_pay_setup,
      evaluate_tax_form,
      evaluate_payment_method
    ]

    Result.new(
      employee_id: employee.id,
      rates_on: rates_on,
      w4_on: w4_on,
      readiness_gate_enforced: employee.readiness_gate_enforced?,
      rehire_or_grandfathered: rehire_or_grandfathered?,
      items: items,
      direct_deposit_missing_bank_details: direct_deposit_missing_bank_details?
    )
  end

  private

  attr_reader :employee, :rates_on, :w4_on, :today

  def rehire_or_grandfathered?
    return @rehire_or_grandfathered if defined?(@rehire_or_grandfathered)

    @rehire_or_grandfathered = !employee.readiness_gate_enforced? || rehired? || prior_committed_payroll?
  end

  def new_client_hire?
    !rehire_or_grandfathered?
  end

  def rehired?
    return @preloaded_rehired unless @preloaded_rehired.nil?

    if employee.association(:employee_status_events).loaded?
      employee.employee_status_events.any? do |event|
        event.event_type == "reactivated" && event.previous_status == "terminated"
      end
    else
      employee.persisted? && employee.employee_status_events.where(
        event_type: "reactivated",
        previous_status: "terminated"
      ).exists?
    end
  end

  def prior_committed_payroll?
    return @preloaded_prior_committed_payroll unless @preloaded_prior_committed_payroll.nil?
    return false unless employee.persisted?

    employee.payroll_items
      .joins(:pay_period)
      .financially_reportable
      .where(pay_periods: { status: "committed" })
      .exists?
  end

  def direct_deposit_missing_bank_details?
    employee.payment_delivery_method == "direct_deposit" &&
      (employee.bank_routing_number_encrypted.blank? || employee.bank_account_number_encrypted.blank?)
  end

  def evaluate_legal_name
    has_personal = employee.first_name.present? && employee.last_name.present?
    if employee.business_contractor?
      complete = has_personal && employee.business_name.present?
      missing_label = if !has_personal
        "legal name missing"
      elsif employee.business_name.blank?
        "business name missing"
      end
    else
      complete = has_personal
      missing_label = complete ? nil : "legal name missing"
    end

    Item.new(
      key: "legal_name",
      label: "Legal name",
      complete: complete,
      applicable: true,
      missing_label: missing_label,
      metadata: {}
    )
  end

  def evaluate_tax_id
    complete = self.class.tax_id_complete?(employee)
    missing_label = if complete
      nil
    elsif employee.business_contractor?
      "business EIN missing"
    elsif employee.contractor?
      "TIN (SSN or EIN) missing"
    else
      "SSN missing"
    end

    Item.new(
      key: "tax_id",
      label: "Tax ID (SSN / TIN)",
      complete: complete,
      applicable: true,
      missing_label: missing_label,
      metadata: {}
    )
  end

  def evaluate_date_of_birth
    if employee.contractor?
      return Item.new(
        key: "date_of_birth",
        label: "Date of birth",
        complete: true,
        applicable: false,
        missing_label: nil,
        metadata: {}
      )
    end

    dob = employee.date_of_birth
    complete = dob.present? && dob.year >= 1900 && dob < today

    Item.new(
      key: "date_of_birth",
      label: "Date of birth",
      complete: complete,
      applicable: true,
      missing_label: complete ? nil : "date of birth missing",
      metadata: {}
    )
  end

  def evaluate_hire_date
    hire_date = employee.hire_date
    plausible = hire_date.present? && hire_date.year.between?(1900, today.year + 1)
    complete = plausible && hire_date <= rates_on
    label = employee.contractor? ? "Start date" : "Hire date"

    missing_label = if complete
      nil
    elsif plausible && hire_date > rates_on
      noun = employee.contractor? ? "start date" : "hire date"
      "#{noun} not effective until #{format_date(hire_date)} — after #{format_date(rates_on)} period"
    else
      employee.contractor? ? "start date missing" : "hire date missing"
    end

    metadata = if plausible && hire_date > rates_on
      { effective_on: hire_date.iso8601, target_date: rates_on.iso8601 }
    else
      {}
    end

    Item.new(
      key: "hire_date",
      label: label,
      complete: complete,
      applicable: true,
      missing_label: missing_label,
      metadata: metadata
    )
  end

  def evaluate_home_address
    complete = employee.address_line1.present? && employee.city.present? && employee.state.present? && employee.zip.present?
    label = employee.contractor? ? "Mailing address" : "Home address"
    missing_label = if complete
      nil
    elsif employee.contractor?
      "mailing address missing"
    else
      "home address missing"
    end

    Item.new(
      key: "home_address",
      label: label,
      complete: complete,
      applicable: true,
      missing_label: missing_label,
      metadata: {}
    )
  end

  def evaluate_pay_setup
    compensation = employee.payroll_compensation_on(rates_on)
    employment_type = compensation.employment_type
    pay_frequency = compensation.pay_frequency
    pay_rate = compensation.pay_rate.to_d
    salary_type = compensation.salary_type
    contractor_pay_type = compensation.contractor_pay_type

    complete, reason_kind = case employment_type
    when "hourly"
      if pay_frequency.blank?
        [ false, :incomplete ]
      elsif pay_rate.positive? || positive_wage_rate_on?(rates_on)
        [ true, nil ]
      else
        [ false, :rate_missing ]
      end
    when "salary"
      if pay_frequency.blank? || !Employee::SALARY_TYPES.include?(salary_type)
        [ false, :incomplete ]
      elsif salary_type == "variable" || pay_rate.positive?
        [ true, nil ]
      else
        [ false, :rate_missing ]
      end
    when "contractor"
      if pay_frequency.blank? || !Employee::CONTRACTOR_PAY_TYPES.include?(contractor_pay_type)
        [ false, :incomplete ]
      elsif contractor_pay_type == "flat_fee"
        [ pay_rate >= 0, (pay_rate >= 0 ? nil : :incomplete) ]
      elsif pay_rate.positive? || positive_wage_rate_on?(rates_on)
        [ true, nil ]
      else
        [ false, :rate_missing ]
      end
    else
      [ false, :incomplete ]
    end

    metadata = {}
    missing_label = if complete
      nil
    elsif reason_kind == :rate_missing
      future_rate_date = earliest_future_positive_rate_date(employment_type)
      if future_rate_date
        metadata = { effective_on: future_rate_date.iso8601, target_date: rates_on.iso8601 }
        "pay rate not effective until #{format_date(future_rate_date)} — missing for #{format_date(rates_on)} period"
      else
        "pay rate missing"
      end
    else
      "pay setup incomplete"
    end

    Item.new(
      key: "pay_setup",
      label: "Pay type, rate & frequency",
      complete: complete,
      applicable: true,
      missing_label: missing_label,
      metadata: metadata
    )
  end

  def evaluate_tax_form
    if employee.contractor?
      complete = employee.w9_on_file == true
      return Item.new(
        key: "tax_form",
        label: "Form W-9",
        complete: complete,
        applicable: true,
        missing_label: complete ? nil : "W-9 not marked on file",
        metadata: {}
      )
    end

    election = employee.w4_election_on(w4_on)
    valid_source = election.present? && election.source != "default_withholding"
    valid_version = valid_source && (!new_client_hire? || election.w4_form_version.to_i >= Employee::MIN_SUPPORTED_W4_FORM_VERSION)
    complete = valid_source && valid_version

    metadata = {}
    missing_label = if complete
      nil
    else
      future_w4_date = earliest_future_valid_w4_date
      if future_w4_date
        metadata = { effective_on: future_w4_date.iso8601, target_date: w4_on.iso8601 }
        "W-4 not effective until #{format_date(future_w4_date)} — missing for #{format_date(w4_on)} payday"
      elsif valid_source && !valid_version
        "2020 or newer W-4 required"
      else
        "W-4 missing"
      end
    end

    Item.new(
      key: "tax_form",
      label: "Form W-4",
      complete: complete,
      applicable: true,
      missing_label: missing_label,
      metadata: metadata
    )
  end

  def evaluate_payment_method
    method = employee.payment_delivery_method
    valid_explicit = Employee::PAYMENT_DELIVERY_METHODS.include?(method)

    complete = if new_client_hire?
      valid_explicit
    else
      method.nil? || valid_explicit
    end

    missing_label = if complete
      nil
    elsif new_client_hire?
      "payment method not chosen"
    else
      "payment method invalid"
    end

    metadata = {}
    metadata[:direct_deposit_missing_bank_details] = true if direct_deposit_missing_bank_details?
    metadata[:effective_method] = method.presence || "paper_check" if complete

    Item.new(
      key: "payment_method",
      label: "Payment method",
      complete: complete,
      applicable: true,
      missing_label: missing_label,
      metadata: metadata
    )
  end

  def positive_wage_rate_on?(date)
    employee.wage_rates_on(date).any? { |rate| rate.active? && rate.rate.to_d.positive? }
  end

  def earliest_future_positive_rate_date(employment_type)
    dates = []
    comp_changes = if employee.association(:employee_compensation_changes).loaded?
      employee.employee_compensation_changes
    else
      employee.employee_compensation_changes.to_a
    end
    comp_changes.each do |change|
      next if change.effective_on <= rates_on
      next unless change.pay_rate.to_d.positive?

      dates << change.effective_on
    end

    if employment_type == "hourly" || employment_type == "contractor"
      wage_versions = if employee.association(:employee_wage_rate_versions).loaded?
        employee.employee_wage_rate_versions
      else
        employee.employee_wage_rate_versions.to_a
      end
      wage_versions.each do |version|
        next if version.effective_on <= rates_on
        next unless version.active && version.rate.to_d.positive?

        dates << version.effective_on
      end
    end

    dates.min
  end

  def earliest_future_valid_w4_date
    elections = if employee.association(:employee_w4_elections).loaded?
      employee.employee_w4_elections
    else
      employee.employee_w4_elections.to_a
    end

    elections.filter_map do |election|
      next if election.source == "default_withholding"
      next if new_client_hire? && election.w4_form_version.to_i < Employee::MIN_SUPPORTED_W4_FORM_VERSION

      available_on = [ election.effective_on, election.w4_signed_on ].compact.max
      available_on if available_on > w4_on
    end.min
  end

  def format_date(date)
    date.strftime("%b %-d, %Y")
  end
end
