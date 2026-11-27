# frozen_string_literal: true

require "digest"
require "openssl"

# Captures the mutable employee configuration that influenced a payroll
# calculation. Committed payroll items use this immutable snapshot when a
# later corrective paycheck is recomputed, so profile edits cannot rewrite
# history.
class PayrollCalculationContext
  VERSION = 1

  SCALAR_ATTRIBUTES = %w[
    date_of_birth
    employment_type
    salary_type
    pay_frequency
    filing_status
    allowances
    w4_form_version
    w4_effective_on
    w4_signed_on
    w4_source_reference
    w4_step2_multiple_jobs
    w4_dependent_credit
    w4_step4a_other_income
    w4_step4b_deductions
    additional_withholding
    retirement_rate
    roth_retirement_rate
    employer_retirement_match_rate
    employer_roth_match_rate
    contractor_pay_type
  ].freeze

  REQUIRED_FOR_CORRECTION = %w[
    employment_type
    salary_type
    pay_frequency
    filing_status
    allowances
    w4_form_version
    w4_step2_multiple_jobs
    w4_dependent_credit
    w4_step4a_other_income
    w4_step4b_deductions
    additional_withholding
    retirement_rate
    roth_retirement_rate
    employer_retirement_match_rate
    employer_roth_match_rate
  ].freeze

  class << self
    def capture(employee:, employee_deductions:, payroll_field_assignments:, w4_election: nil, w4_profile: w4_election&.profile_attributes, retirement_election: nil, rates_on: PayrollBusinessClock.today, employee_basis: nil, pay_period: nil, payroll_item: nil, preserve_entered_pay_rates: false)
      snapshot = {
        "version" => VERSION,
        "intake_setup_fingerprint" => employee.intake_exception.present? ? intake_setup_fingerprint(employee: employee, rates_on: rates_on) : nil,
        "employee" => employee_snapshot(employee, w4_profile: w4_profile).merge(employee_basis || EmployeeCompensationChangeService.snapshot(employee, rates_on)),
        "employee_deductions" => deduction_snapshots(employee_deductions),
        "payroll_field_assignments" => payroll_field_snapshots(payroll_field_assignments),
        "retirement_election" => retirement_election&.snapshot_attributes&.deep_stringify_keys
      }

      if pay_period.present? && paycheck_fingerprint_scoped?(employee: employee, pay_period: pay_period)
        item_method = payroll_item ? payroll_item.effective_payment_delivery_method : (employee.payment_delivery_method.presence || "paper_check")
        employee_default = employee.payment_delivery_method.presence || "paper_check"
        prior_overridden = payroll_item&.calculation_context_snapshot.to_h["payment_delivery_method_overridden"] == true
        snapshot["paycheck_input_fingerprint"] = paycheck_input_fingerprint(employee: employee, pay_period: pay_period)
        snapshot["item_payment_delivery_method"] = item_method
        snapshot["employee_payment_default_at_calculation"] = employee_default
        snapshot["payment_delivery_method_overridden"] = prior_overridden && item_method != employee_default
        if preserve_entered_pay_rates && payroll_item.present?
          snapshot["preserved_entered_rates"] = preserved_entered_rates_snapshot(payroll_item)
        end
      end

      snapshot
    end

    def preserved_entered_rates_snapshot(payroll_item)
      {
        "pay_rate" => payroll_item.pay_rate.to_d.to_s("F"),
        "wage_rate_hours" => payroll_item.wage_rate_hours.map do |entry|
          {
            "employee_wage_rate_id" => entry["employee_wage_rate_id"].presence&.to_i,
            "label" => entry["label"].to_s.strip.downcase,
            "rate" => entry["rate"].to_d.to_s("F")
          }
        end
      }
    end

    def paycheck_fingerprint_scoped?(employee:, pay_period:)
      PayrollReadinessPolicy.fingerprint_scoped?(employee: employee, pay_period: pay_period)
    end

    # Canonical SHA-256 fingerprint of live period-resolved calculation inputs
    # for readiness_gate_enforced employees and client_managed companies.
    # Deliberately excludes employee_loans (which mutate on commit of other runs
    # and enforce their own balance/schedule check on commit) and separates
    # payment_delivery_method into state-aware snapshot keys (§6.3B).
    def paycheck_input_fingerprint(employee:, pay_period:)
      rates_on = pay_period.end_date
      w4_on = pay_period.pay_date
      dated_employee = dated_employee_attributes(employee, rates_on)

      compensation_fields = %w[
        pay_rate employment_type salary_type pay_frequency
        contractor_pay_type contractor_type
        default_custom_earnings default_payroll_adjustments
        date_of_birth retirement_rate roth_retirement_rate
        employer_retirement_match_rate employer_roth_match_rate
        additional_withholding
      ]

      election = dated_employee["employment_type"] == "contractor" ? nil : employee.w4_election_on(w4_on)
      w4_payload = if dated_employee["employment_type"] == "contractor"
        { "contractor" => true, "w9_on_file" => employee.w9_on_file == true }
      elsif election
        {
          "election_id" => election.id,
          "source" => election.source,
          "effective_on" => election.effective_on&.iso8601,
          "w4_signed_on" => election.w4_signed_on&.iso8601,
          "profile" => election.profile_attributes.deep_stringify_keys
        }
      else
        {
          "election_id" => nil,
          "source" => nil,
          "profile" => EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.deep_stringify_keys
        }
      end

      stable_rows = lambda do |association|
        columns = %w[created_at updated_at]
        columns << "company_id" if association.klass < CompanyFromParent
        association.reorder(:id).map { |row| row.attributes.except(*columns) }
      end

      payload = {
        "compensation" => dated_employee.slice(*compensation_fields),
        "wage_rates" => dated_wage_rate_attributes(employee, rates_on).map { |row| row.except("created_at", "updated_at") },
        "w4" => w4_payload,
        "tax_id_digest" => tax_id_digest(employee),
        "status_boundaries" => {
          "status" => employee.status,
          "hire_date" => employee.hire_date&.iso8601,
          "termination_date" => employee.termination_date&.iso8601
        },
        "deductions" => deduction_snapshots(employee.employee_deductions.includes(:deduction_type).reorder(:id)),
        "deduction_assignments" => stable_rows.call(employee.employee_deductions),
        "payroll_fields" => payroll_field_snapshots(employee.employee_payroll_fields.includes(:payroll_field_definition).reorder(:id)),
        "payroll_field_assignments" => stable_rows.call(employee.employee_payroll_fields),
        "retirement_elections" => stable_rows.call(employee.employee_retirement_elections),
        "retirement_year_inputs" => stable_rows.call(employee.employee_retirement_year_inputs)
      }

      Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))
    end

    # For new intake exceptions only. This guards a calculation against later
    # manager reconfirmation of different compensation/configuration without
    # rewriting the immutable evidence on committed payroll items.
    def intake_setup_fingerprint(employee:, rates_on: PayrollBusinessClock.today)
      scalar_fields = SCALAR_ATTRIBUTES + %w[
        pay_rate hire_date intake_payroll_eligible_from contractor_type default_custom_earnings default_payroll_adjustments
      ]
      stable_rows = lambda do |association|
        columns = %w[created_at updated_at]
        columns << "company_id" if association.klass < CompanyFromParent
        association.reorder(:id).map { |row| row.attributes.except(*columns) }
      end
      setup = {
        "employee" => dated_employee_attributes(employee, rates_on).slice(*scalar_fields),
        "wage_rates" => dated_wage_rate_attributes(employee, rates_on).map { |row| row.except("created_at", "updated_at") },
        "deductions" => deduction_snapshots(employee.employee_deductions.includes(:deduction_type).reorder(:id)),
        "deduction_assignments" => stable_rows.call(employee.employee_deductions),
        "payroll_fields" => payroll_field_snapshots(employee.employee_payroll_fields.includes(:payroll_field_definition).reorder(:id)),
        "payroll_field_assignments" => stable_rows.call(employee.employee_payroll_fields),
        "retirement_elections" => stable_rows.call(employee.employee_retirement_elections),
        "retirement_year_inputs" => stable_rows.call(employee.employee_retirement_year_inputs),
        "loans" => stable_rows.call(employee.employee_loans)
      }
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(setup)))
    end

    # Preserve the pre-history fingerprint payload when only backfilled setup
    # applies. Later versions affect evidence only on the proof's own date.
    def dated_employee_attributes(employee, date)
      employee.attributes.except("company_job_role_id", "legacy_stub_regular_wage_label").merge(EmployeeCompensationChangeService.snapshot(employee, date))
    end

    def dated_wage_rate_attributes(employee, date)
      employee.wage_rates_on(date, include_inactive: true).sort_by(&:id).map { |row| row.attributes.except("company_id") }
    end

    def valid_for_correction?(snapshot)
      data = snapshot.to_h.deep_stringify_keys
      employee_data = data["employee"].to_h

      data["version"].to_i == VERSION &&
        REQUIRED_FOR_CORRECTION.all? { |key| employee_data.key?(key) } &&
        data["employee_deductions"].is_a?(Array) &&
        data["payroll_field_assignments"].is_a?(Array)
    end

    def employee_value(snapshot, attribute)
      snapshot.to_h.deep_stringify_keys.dig("employee", attribute.to_s)
    end

    def employee_deductions(snapshot)
      Array(snapshot.to_h.deep_stringify_keys["employee_deductions"]).map do |entry|
        type_data = entry.fetch("deduction_type")
        deduction_type = DeductionType.new(type_data.except("id"))
        deduction_type.id = type_data["id"]

        EmployeeDeduction.new(
          amount: entry["amount"],
          is_percentage: entry["is_percentage"],
          active: true,
          deduction_type: deduction_type
        )
      end
    end

    def payroll_field_assignments(snapshot)
      Array(snapshot.to_h.deep_stringify_keys["payroll_field_assignments"]).map do |entry|
        definition_data = entry.fetch("definition")
        definition = PayrollFieldDefinition.new(definition_data.except("id"))
        definition.id = definition_data["id"]

        EmployeePayrollField.new(
          amount: entry["amount"],
          percentage: entry["percentage"],
          active: true,
          start_date: entry["start_date"],
          end_date: entry["end_date"],
          notes: entry["notes"],
          payroll_field_definition: definition
        )
      end
    end

    def retirement_election(snapshot)
      snapshot.to_h.deep_stringify_keys["retirement_election"]
    end

    private

    def tax_id_digest(employee)
      ssn_digits = employee.ssn_encrypted.to_s.gsub(/\D/, "")
      ein_digits = employee.contractor_ein.to_s.gsub(/\D/, "")
      key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key("paycheck_input_fingerprint_tax_id", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, "#{employee.company_id}:#{employee.id}:#{ssn_digits}:#{ein_digits}")
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h { |key| [ key, canonicalize(value[key]) ] }
      when Array
        value.map { |entry| canonicalize(entry) }
      when BigDecimal
        value.to_s("F")
      when Date, Time, ActiveSupport::TimeWithZone
        value.iso8601
      else
        value
      end
    end

    def employee_snapshot(employee, w4_profile:)
      SCALAR_ATTRIBUTES.index_with do |attribute|
        value = if w4_profile&.key?(attribute.to_sym)
          w4_profile.fetch(attribute.to_sym)
        else
          employee.public_send(attribute)
        end
        value.respond_to?(:iso8601) ? value.iso8601 : value
      end
    end

    def deduction_snapshots(deductions)
      deductions.map do |deduction|
        deduction_type = deduction.deduction_type
        {
          "amount" => deduction.amount.to_f,
          "is_percentage" => deduction.is_percentage?,
          "deduction_type" => {
            "id" => deduction_type.id,
            "company_id" => deduction_type.company_id,
            "name" => deduction_type.name,
            "category" => deduction_type.category,
            "sub_category" => deduction_type.sub_category,
            "reporting_group" => deduction_type.reporting_group,
            "active" => deduction_type.active,
            "generates_check" => deduction_type.generates_check
          }
        }
      end
    end

    def payroll_field_snapshots(assignments)
      assignments.map do |assignment|
        definition = assignment.payroll_field_definition
        {
          "amount" => assignment.amount&.to_f,
          "percentage" => assignment.percentage&.to_f,
          "start_date" => assignment.start_date&.iso8601,
          "end_date" => assignment.end_date&.iso8601,
          "notes" => assignment.notes,
          "definition" => {
            "id" => definition.id,
            "company_id" => definition.company_id,
            "name" => definition.name,
            "kind" => definition.kind,
            "tax_treatment" => definition.tax_treatment,
            "category" => definition.category,
            "amount_type" => definition.amount_type,
            "default_amount" => definition.default_amount&.to_f,
            "default_percentage" => definition.default_percentage&.to_f,
            "reporting_group" => definition.reporting_group,
            "active" => definition.active,
            "show_in_payroll_grid" => definition.show_in_payroll_grid
          }
        }
      end
    end
  end
end
