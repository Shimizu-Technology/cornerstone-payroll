# frozen_string_literal: true

require "digest"
require "set"

class PayrollGoLiveSetupPlan
  COMPANY_FIELDS = %w[
    address_line1 address_line2 city state zip phone email bank_name bank_address
    pay_frequency payroll_intake_source_types simple_payroll_register_enabled auto_create_fit_check
    check_stock_type check_offset_x check_offset_y check_layout_config active_printer_profile_id next_check_number
  ].freeze

  attr_reader :company, :source_company, :batch, :effective_on, :employee_matches,
    :errors, :warnings, :summary, :plan, :digest

  def initialize(company:, source_company:, batch:, effective_on:)
    @company = company
    @source_company = source_company
    @batch = batch
    @effective_on = effective_on.to_date
  end

  def call
    @employee_matches, match_errors = build_employee_matches
    @errors = base_errors + match_errors
    @warnings = build_warnings
    @summary = build_summary
    @plan = {
      "source_company_id" => source_company.id,
      "company_id" => company.id,
      "historical_import_batch_id" => batch.id,
      "effective_on" => effective_on.iso8601,
      "employee_matches" => employee_matches.map do |source, target|
        { "source_employee_id" => source.id, "employee_id" => target.id, "employee_name" => target.full_name }
      end
    }
    @digest = Digest::SHA256.hexdigest(JSON.generate(fingerprint_payload))
    self
  end

  def ready?
    errors.empty?
  end

  private

  def base_errors
    values = []
    values << "The source and successor clients must be different" if company.id == source_company.id
    values << "Both clients must belong to the same organization" if company.organization_id != source_company.organization_id
    values << "Lock the verified historical import before copying live setup" unless batch.locked?
    values << "Prepare the successor employee roster before copying live setup" unless batch.historical_client_bootstrap&.applied?
    values << "The successor already has committed Cornerstone payroll" if company.pay_periods.committed.exists?

    source_schedule = current_source_schedule
    source_workweek = current_source_workweek
    values << "Confirm the source client's pay schedule before transfer" unless source_schedule&.confirmed?
    values << "Confirm the source client's legal workweek before transfer" unless source_workweek&.confirmed?
    if source_workweek&.starts_at_minutes.to_i != 0
      values << "The source legal workweek must begin at midnight for date-based payroll records"
    end

    destination_latest = [
      company.company_pay_schedules.maximum(:effective_on),
      company.company_workweeks.maximum(:effective_on)
    ].compact.max
    if destination_latest && effective_on <= destination_latest
      values << "The transfer date must be after the successor's current setup date (#{destination_latest})"
    end
    values
  end

  def build_employee_matches
    source_index = Hash.new { |hash, key| hash[key] = [] }
    source_company.employees.active.find_each do |employee|
      employee_name_keys(employee).each { |key| source_index[key] << employee }
    end

    matches = []
    errors = []
    matched_source_ids = Set.new
    company.employees.active.order(:last_name, :first_name, :id).each do |target|
      candidates = employee_name_keys(target).flat_map { |key| source_index[key] }.uniq
      if candidates.one?
        source = candidates.first
        if matched_source_ids.include?(source.id)
          errors << "#{target.full_name}: the source employee is already matched to another successor employee"
        elsif source.employment_type != target.employment_type
          errors << "#{target.full_name}: source and successor tax classifications do not match"
        else
          matches << [ source, target ]
          matched_source_ids << source.id
        end
      elsif candidates.empty?
        errors << "#{target.full_name}: no active source employee match"
      else
        errors << "#{target.full_name}: multiple source employees have the same normalized name"
      end
    end

    source_company.employees.active.where.not(id: matched_source_ids.to_a).find_each do |source|
      errors << "#{source.full_name}: active source employee has no successor match"
    end
    [ matches, errors ]
  end

  def employee_name_keys(employee)
    [
      [ employee.first_name, employee.middle_name, employee.last_name ],
      [ employee.last_name, employee.first_name, employee.middle_name ]
    ].map { |parts| QuickbooksHistory::NameNormalizer.call(parts.compact_blank.join(" ")) }.uniq
  end

  def current_source_schedule
    @current_source_schedule ||= CompanyPaySchedule.for_date(source_company.id, effective_on)
  end

  def current_source_workweek
    @current_source_workweek ||= CompanyWorkweek.for_date(source_company.id, effective_on)
  end

  def build_warnings
    values = [
      "Paid payroll, checks, tax filings, YTD rows, loan transactions, and audit history are never copied.",
      "The source EIN is not moved during setup transfer. Complete the legal-employer handoff only after go-live approval.",
      "Loan deduction schedules are copied without balances; each opening balance must be independently verified."
    ]
    values << "The source client has no EIN recorded" if source_company.ein.blank?
    values
  end

  def build_summary
    {
      "employee_count" => employee_matches.size,
      "department_count" => source_company.departments.active.count,
      "payroll_field_count" => source_company.payroll_field_definitions.active.count,
      "deduction_type_count" => source_company.deduction_types.active.count,
      "recurring_deduction_count" => EmployeeDeduction.active.joins(:employee).where(employees: { company_id: source_company.id }).count,
      "recurring_payroll_field_count" => EmployeePayrollField.active.joins(:employee).where(employees: { company_id: source_company.id }).count,
      "work_profile_count" => employee_matches.count { |source, _target| EmployeeWorkProfile.for_date(source.id, effective_on).present? },
      "sensitive_profile_count" => employee_matches.count do |source, _target|
        source.ssn_encrypted.present? || source.bank_account_number_encrypted.present? || source.bank_routing_number_encrypted.present?
      end
    }
  end

  def fingerprint_payload
    records = [ source_company, company, batch, current_source_schedule, current_source_workweek ].compact
    employee_matches.each do |source, target|
      records.concat([ source, target ])
      records.concat(source.employee_w4_elections.to_a)
      records.concat(source.employee_wage_rates.to_a)
      records.concat(source.employee_deductions.to_a)
      records.concat(source.employee_payroll_fields.to_a)
      records.concat(source.employee_work_profiles.to_a)
      records.concat(target.employee_w4_elections.to_a)
      records.concat(target.employee_wage_rates.to_a)
      records.concat(target.employee_deductions.to_a)
      records.concat(target.employee_payroll_fields.to_a)
      records.concat(target.employee_work_profiles.to_a)
    end
    records.concat(source_company.departments.to_a)
    records.concat(source_company.payroll_field_definitions.to_a)
    records.concat(source_company.deduction_types.to_a)
    records.concat(company.departments.to_a)
    records.concat(company.payroll_field_definitions.to_a)
    records.concat(company.deduction_types.to_a)

    {
      "plan" => plan,
      "records" => records.uniq.sort_by { |record| [ record.class.name, record.id ] }.map do |record|
        [ record.class.name, record.id, record.updated_at&.iso8601(6) ]
      end,
      "company_fields" => source_company.attributes.slice(*COMPANY_FIELDS)
    }
  end
end
