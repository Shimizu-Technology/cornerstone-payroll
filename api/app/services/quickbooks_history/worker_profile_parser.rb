# frozen_string_literal: true

require "strscan"

module QuickbooksHistory
  class WorkerProfileParser
    ParsedProfile = Data.define(
      :worker,
      :employee_attributes,
      :wage_rates,
      :payroll_fields,
      :review_items,
      :warnings,
      :errors
    ) do
      def active?
        employee_attributes.fetch(:status) == "active"
      end

      def digest_payload
        {
          historical_worker_id: worker.id,
          employee_attributes: employee_attributes,
          wage_rates: wage_rates,
          payroll_fields: payroll_fields,
          review_items: review_items,
          warnings: warnings,
          errors: errors
        }
      end
    end

    PLACEHOLDER_DEDUCTION_MAXIMUM = BigDecimal("1.00")

    def initialize(worker:, pay_frequency:)
      @worker = worker
      @pay_frequency = pay_frequency
    end

    def call
      @review_items = []
      @warnings = []
      @errors = []
      snapshot = worker.private_snapshot_data
      directory = snapshot.fetch("_employee_directory", {})
      details = snapshot.except("_employee_directory")
      if directory.blank?
        errors << "QuickBooks employee directory setup is missing from the retained snapshot; import the source with the current importer before creating live employees"
      end
      first_name, middle_name, last_name = parse_name(worker.source_name)
      tax = parse_tax(details.fetch("Tax info", ""))
      pay = parse_pay(details.fetch("Pay info", ""), active: worker.source_status == "active")
      address = parse_address(directory.fetch("Home address", ""))

      review(
        code: "verify_hire_date",
        message: "QuickBooks hire dates were retained with the source evidence but were not copied into live payroll. Confirm the effective hire date.",
        fields: %w[hire_date]
      )
      review_address(address)

      attributes = {
        first_name: first_name,
        middle_name: middle_name,
        last_name: last_name,
        email: directory.fetch("Email", "").presence,
        date_of_birth: parse_optional_date(directory.fetch("Birth date", ""), "birth date"),
        hire_date: nil,
        employment_type: pay.fetch(:employment_type),
        salary_type: pay.fetch(:salary_type),
        pay_rate: pay.fetch(:pay_rate),
        pay_frequency: pay_frequency,
        filing_status: tax.fetch(:filing_status),
        allowances: tax.fetch(:allowances),
        w4_dependent_credit: tax.fetch(:dependent_credit),
        w4_form_version: Employee::MIN_SUPPORTED_W4_FORM_VERSION,
        w4_step2_multiple_jobs: false,
        w4_step4a_other_income: 0,
        w4_step4b_deductions: 0,
        additional_withholding: 0,
        retirement_rate: pay.fetch(:retirement_rate),
        roth_retirement_rate: pay.fetch(:roth_retirement_rate),
        employer_retirement_match_rate: pay.fetch(:employer_retirement_match_rate),
        employer_roth_match_rate: pay.fetch(:employer_roth_match_rate),
        status: worker.source_status == "active" ? "active" : "inactive",
        ssn_encrypted: tax.fetch(:ssn),
        address_line1: address[:address_line1],
        city: address[:city],
        state: address[:state],
        zip: address[:zip],
        configuration_source: "quickbooks_history",
        configuration_review_status: review_items.any? ? "needs_review" : "complete",
        configuration_review_items: review_items
      }

      ParsedProfile.new(
        worker: worker,
        employee_attributes: attributes,
        wage_rates: pay.fetch(:wage_rates),
        payroll_fields: pay.fetch(:payroll_fields),
        review_items: review_items,
        warnings: warnings,
        errors: errors
      )
    end

    private

    attr_reader :worker, :pay_frequency, :review_items, :warnings, :errors

    def parse_name(source_name)
      clean = source_name.to_s.delete_prefix("*").squish
      last_name, given_names = clean.split(",", 2).map(&:strip)
      parts = given_names.to_s.split
      first_name = parts.shift
      if first_name.blank? || last_name.blank?
        errors << "QuickBooks worker name cannot be separated into first and last name"
      end

      [ first_name, parts.join(" ").presence, last_name ]
    end

    def parse_tax(text)
      ssn = text.match(/\b\d{3}-?\d{2}-?\d{4}\b/)&.to_s&.gsub(/\D/, "")
      errors << "QuickBooks tax setup is missing a valid Social Security number" unless ssn&.length == 9

      filing_status = case text
      when /Head of Household/i then "head_of_household"
      when /Married Filing Jointly|Qualifying Surviving Spouse/i then "married"
      when /Single or Married Filing Separately|\bSingle\b/i then "single"
      else
        errors << "QuickBooks tax setup has an unsupported filing status"
        "single"
      end

      allowances = text.match(/Withholding allowances:\s*(\d+)/i)&.captures&.first.to_i
      if text.match?(/Withholding allowances:/i)
        review(
          code: "legacy_w4_allowances",
          message: "QuickBooks supplied legacy withholding allowances. Confirm a current W-4 before relying on automatic FIT; a pay-period FIT override remains available meanwhile.",
          fields: %w[allowances w4_form_version]
        )
      end

      dependent_credit = decimal(text.match(/Claim dependents amount:\s*\$([\d,]+(?:\.\d+)?)/i)&.captures&.first)
      {
        ssn: ssn,
        filing_status: filing_status,
        allowances: allowances,
        dependent_credit: dependent_credit
      }
    end

    def parse_pay(text, active:)
      compensation, deductions, contributions, time_off = split_pay_sections(text)
      wage_rates = parse_wage_rates(compensation)
      commission_only = compensation.match?(/Pay type:\s*Commission Only/i)

      if commission_only
        review(
          code: "commission_only_variable_pay",
          message: "QuickBooks marks this worker as commission-only. They were prepared as variable salary so each payroll requires an explicit period amount.",
          fields: %w[employment_type salary_type pay_rate]
        )
      elsif wage_rates.empty?
        errors << "QuickBooks pay setup does not contain a supported hourly rate or commission-only pay type"
      end

      deduction_items = parse_money_or_percent_items(deductions, "deductions")
      contribution_items = parse_money_or_percent_items(contributions, "contributions")
      configuration = parse_current_configuration(
        deductions: deduction_items,
        contributions: contribution_items,
        active: active
      )

      if active && time_off.present? && time_off.casecmp("None") != 0
        review(
          code: "time_off_setup_not_imported",
          message: "QuickBooks contains a time-off payroll item. Its policy and balance need accountant review before configuration.",
          fields: []
        )
      end

      {
        employment_type: commission_only ? "salary" : "hourly",
        salary_type: commission_only ? "variable" : "annual",
        pay_rate: commission_only ? 0.to_d : wage_rates.first&.fetch(:rate, 0.to_d),
        wage_rates: commission_only ? [] : wage_rates,
        payroll_fields: configuration.fetch(:payroll_fields),
        retirement_rate: configuration.fetch(:retirement_rate),
        roth_retirement_rate: configuration.fetch(:roth_retirement_rate),
        employer_retirement_match_rate: configuration.fetch(:employer_retirement_match_rate),
        employer_roth_match_rate: configuration.fetch(:employer_roth_match_rate)
      }
    end

    def split_pay_sections(text)
      match = text.match(/\A(?<compensation>.*?)\s+Pay method:\s*(?<method>.*?)\s+Deductions:\s*(?<deductions>.*?)\s+Contributions:\s*(?<contributions>.*?)\s+Time off:\s*(?<time_off>.*)\z/i)
      unless match
        errors << "QuickBooks pay setup could not be separated into compensation, deductions, contributions, and time off"
        return [ "", "", "", "" ]
      end

      warnings << "QuickBooks pay method is not Check" unless match[:method].to_s.casecmp("Check").zero?
      [ match[:compensation], match[:deductions], match[:contributions], match[:time_off] ]
    end

    def parse_wage_rates(text)
      text.scan(/(?:\A|\s)([^:]+?):\s*\$([\d,]+(?:\.\d+)?)\/hr(?=\s|\z)/).map.with_index do |(label, value), index|
        {
          label: label.squish,
          rate: decimal(value),
          is_primary: index.zero?,
          active: true
        }
      end
    end

    def parse_money_or_percent_items(text, section)
      return [] if text.blank? || text.casecmp("None").zero?

      scanner = StringScanner.new(text)
      items = []
      until scanner.eos?
        scanner.skip(/\s+/)
        match = scanner.scan_until(/:\s*(\$[\d,]+(?:\.\d+)?|[\d.]+%)(?=\s|\z)/)
        unless match
          errors << "QuickBooks #{section} contain an unreadable item"
          break
        end

        label, raw_value = match.match(/\A(.+?):\s*(\$[\d,]+(?:\.\d+)?|[\d.]+%)\z/).captures
        items << if raw_value.end_with?("%")
          { label: label.squish, value: decimal(raw_value.delete_suffix("%")), value_type: "percentage" }
        else
          { label: label.squish, value: decimal(raw_value.delete_prefix("$")), value_type: "fixed" }
        end
      end
      items
    end

    def parse_current_configuration(deductions:, contributions:, active:)
      result = {
        payroll_fields: [],
        retirement_rate: 0.to_d,
        roth_retirement_rate: 0.to_d,
        employer_retirement_match_rate: 0.to_d,
        employer_roth_match_rate: 0.to_d
      }
      return result unless active

      deductions.each do |item|
        label = item.fetch(:label)
        value = item.fetch(:value)
        next if value.zero?

        if label.match?(/\A401\(k\) After Tax\z/i) && item.fetch(:value_type) == "percentage"
          result[:roth_retirement_rate] = rate_fraction(value)
        elsif label.match?(/\A401\(k\) Pre-Tax\z/i) && item.fetch(:value_type) == "percentage"
          result[:retirement_rate] = rate_fraction(value)
        elsif placeholder_deduction?(label, value)
          warnings << "A QuickBooks placeholder deduction was intentionally not activated"
        else
          field = payroll_field_for(item)
          field ? result[:payroll_fields] << field : errors << "QuickBooks deduction '#{safe_label(label)}' needs an explicit tax/category mapping"
        end
      end

      contributions.each do |item|
        next if item.fetch(:value).zero?

        label = item.fetch(:label)
        unless item.fetch(:value_type) == "percentage"
          errors << "QuickBooks employer contribution '#{safe_label(label)}' is not percentage-based"
          next
        end

        if label.match?(/\A401\(k\) After Tax\z/i)
          result[:employer_roth_match_rate] = rate_fraction(item.fetch(:value))
        elsif label.match?(/\A401\(k\) Pre-Tax\z/i)
          result[:employer_retirement_match_rate] = rate_fraction(item.fetch(:value))
        else
          errors << "QuickBooks employer contribution '#{safe_label(label)}' needs an explicit mapping"
        end
      end

      result
    end

    def payroll_field_for(item)
      label = item.fetch(:label)
      value_type = item.fetch(:value_type)
      value = item.fetch(:value)
      attributes = case label
      when /401\(k\).*Pre-Tax/i
        [ "pre_tax_deduction", "retirement", PayrollReportingGroups::GROUP_401K_PRE_TAX ]
      when /401\(k\).*After Tax/i
        [ "post_tax_deduction", "retirement", PayrollReportingGroups::GROUP_401K_AFTER_TAX ]
      when /Health Insurance/i
        [ "post_tax_deduction", "insurance", nil ]
      when /\bRent\b/i
        [ "post_tax_deduction", "rent", nil ]
      when /\bPhone\b/i
        [ "post_tax_deduction", "phone", nil ]
      when /Allotment/i
        review_obligation(label)
        [ "post_tax_deduction", "allotment", nil ]
      when /Remittance ID|Case No\./i
        review_obligation(label)
        [ "post_tax_deduction", "child_support", nil ]
      when /Loan|Advance/i
        review_obligation(label)
        [ "post_tax_deduction", "loan", nil ]
      else
        return nil
      end

      treatment, category, reporting_group = attributes
      {
        name: label,
        kind: "deduction",
        tax_treatment: treatment,
        category: category,
        amount_type: value_type,
        amount: value_type == "fixed" ? value : nil,
        percentage: value_type == "percentage" ? value : nil,
        reporting_group: reporting_group
      }
    end

    def placeholder_deduction?(label, value)
      label.casecmp("Loan").zero? && value <= PLACEHOLDER_DEDUCTION_MAXIMUM
    end

    def review_obligation(_label)
      review(
        code: "obligation_terms_missing",
        message: "A loan, advance, child-support, garnishment, or allotment item was prepared as a per-payroll deduction. QuickBooks did not provide its balance, priority, limits, recipient instructions, or stop condition.",
        fields: []
      )
    end

    def review_address(address)
      if address[:suppressed]
        review(
          code: "quickbooks_nevada_address_suppressed",
          message: "QuickBooks exported a Nevada employee address for this Guam payroll client. It was retained in private evidence but not copied into live payroll.",
          fields: %w[address_line1 city state zip]
        )
      elsif address.values_at(:address_line1, :city, :state, :zip).any?(&:blank?)
        review(
          code: "employee_address_missing",
          message: "QuickBooks did not provide a complete usable employee address.",
          fields: %w[address_line1 city state zip]
        )
      end
    end

    def parse_address(value)
      text = value.to_s.squish
      return { address_line1: nil, city: nil, state: nil, zip: nil, suppressed: false } if text.blank?

      street, city, region_and_zip = text.split(",", 3).map(&:strip)
      region_match = region_and_zip.to_s.match(/\A(?<state>.+?)\s+(?<zip>\d{5}(?:-\d{4})?)\z/)
      state = region_match&.[](:state)
      if state.to_s.match?(/\A(?:NV|Nevada)\z/i)
        return { address_line1: nil, city: nil, state: nil, zip: nil, suppressed: true }
      end

      {
        address_line1: street.presence,
        city: city.presence,
        state: state.presence,
        zip: region_match&.[](:zip),
        suppressed: false
      }
    end

    def parse_optional_date(value, label)
      return nil if value.to_s.blank? || value.to_s == "-"

      Date.strptime(value.to_s, "%m/%d/%Y")
    rescue Date::Error
      errors << "QuickBooks #{label} is invalid"
      nil
    end

    def rate_fraction(percentage)
      (percentage / 100).round(4)
    end

    def decimal(value)
      BigDecimal(value.to_s.delete(",").presence || "0").round(2)
    rescue ArgumentError
      0.to_d
    end

    def review(code:, message:, fields:)
      review_items << { "code" => code, "message" => message, "fields" => fields }
    end

    def safe_label(label)
      label.to_s.gsub(/\([^)]*\)/, "").gsub(/\b\d[\d-]{3,}\b/, "").squish.presence || "Payroll obligation"
    end
  end
end
