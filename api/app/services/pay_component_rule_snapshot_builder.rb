# frozen_string_literal: true

# Captures the rule evidence used to classify payroll components when a
# liability posting is created. This service does not calculate or alter pay;
# payroll_item values remain authoritative. Company-specific database rules
# override the versioned application defaults for the same component key.
class PayComponentRuleSnapshotBuilder
  SCHEMA_VERSION = 1
  DEFAULT_VERSION = "2026.1"

  def self.standard_non_tax_rule(display_name, component_kind)
    {
      display_name: display_name,
      component_kind: component_kind,
      fit_treatment: "not_applicable",
      social_security_treatment: "not_applicable",
      medicare_treatment: "not_applicable",
      additional_medicare_treatment: "not_applicable",
      swica_treatment: "excluded",
      retirement_treatment: display_name.include?("retirement") || display_name.include?("Roth") ? "included" : "excluded",
      reimbursement_treatment: "not_applicable",
      w2_gu_mapping: {},
      form_941_mapping: {},
      register_presentation: "separate",
      source_name: "Stored committed payroll component",
      source_url: nil
    }
  end
  private_class_method :standard_non_tax_rule

  DEFAULT_RULES = {
    "guam_income_tax_withheld" => {
      display_name: "Guam income tax withholding",
      component_kind: "deduction",
      fit_treatment: "not_applicable",
      social_security_treatment: "not_applicable",
      medicare_treatment: "not_applicable",
      additional_medicare_treatment: "not_applicable",
      swica_treatment: "excluded",
      retirement_treatment: "excluded",
      reimbursement_treatment: "not_applicable",
      w2_gu_mapping: { "box" => "2" },
      form_941_mapping: { "line" => "3" },
      register_presentation: "separate",
      source_name: "Stored payroll-item withholding",
      source_url: "https://www.irs.gov/instructions/i941"
    },
    "social_security_employee" => {
      display_name: "Employee Social Security tax",
      component_kind: "deduction",
      fit_treatment: "not_applicable",
      social_security_treatment: "not_applicable",
      medicare_treatment: "not_applicable",
      additional_medicare_treatment: "not_applicable",
      swica_treatment: "excluded",
      retirement_treatment: "excluded",
      reimbursement_treatment: "not_applicable",
      w2_gu_mapping: { "box" => "4" },
      form_941_mapping: { "line" => "5a-5c" },
      register_presentation: "separate",
      source_name: "Stored payroll-item Social Security tax",
      source_url: "https://www.irs.gov/publications/p15"
    },
    "social_security_employer" => {
      display_name: "Employer Social Security tax",
      component_kind: "employer_contribution",
      fit_treatment: "not_applicable",
      social_security_treatment: "not_applicable",
      medicare_treatment: "not_applicable",
      additional_medicare_treatment: "not_applicable",
      swica_treatment: "excluded",
      retirement_treatment: "excluded",
      reimbursement_treatment: "not_applicable",
      w2_gu_mapping: {},
      form_941_mapping: { "line" => "5a-5c" },
      register_presentation: "separate",
      source_name: "Stored payroll-item employer Social Security tax",
      source_url: "https://www.irs.gov/publications/p15"
    },
    "medicare_employee" => {
      display_name: "Employee Medicare tax",
      component_kind: "deduction",
      fit_treatment: "not_applicable",
      social_security_treatment: "not_applicable",
      medicare_treatment: "not_applicable",
      additional_medicare_treatment: "not_applicable",
      swica_treatment: "excluded",
      retirement_treatment: "excluded",
      reimbursement_treatment: "not_applicable",
      w2_gu_mapping: { "box" => "6" },
      form_941_mapping: { "line" => "5c" },
      register_presentation: "separate",
      source_name: "Stored payroll-item Medicare tax",
      source_url: "https://www.irs.gov/publications/p15"
    },
    "medicare_employer" => {
      display_name: "Employer Medicare tax",
      component_kind: "employer_contribution",
      fit_treatment: "not_applicable",
      social_security_treatment: "not_applicable",
      medicare_treatment: "not_applicable",
      additional_medicare_treatment: "not_applicable",
      swica_treatment: "excluded",
      retirement_treatment: "excluded",
      reimbursement_treatment: "not_applicable",
      w2_gu_mapping: {},
      form_941_mapping: { "line" => "5c" },
      register_presentation: "separate",
      source_name: "Stored payroll-item employer Medicare tax",
      source_url: "https://www.irs.gov/publications/p15"
    },
    "additional_medicare_employee" => {
      display_name: "Employee Additional Medicare tax",
      component_kind: "deduction",
      fit_treatment: "not_applicable",
      social_security_treatment: "not_applicable",
      medicare_treatment: "not_applicable",
      additional_medicare_treatment: "not_applicable",
      swica_treatment: "excluded",
      retirement_treatment: "excluded",
      reimbursement_treatment: "not_applicable",
      w2_gu_mapping: { "box" => "6" },
      form_941_mapping: { "line" => "5d" },
      register_presentation: "separate",
      source_name: "Stored payroll-item Additional Medicare tax",
      source_url: "https://www.irs.gov/publications/p15"
    },
    "retirement_employee" => standard_non_tax_rule("Employee pre-tax retirement", "deduction"),
    "roth_retirement_employee" => standard_non_tax_rule("Employee Roth retirement", "deduction"),
    "retirement_employer" => standard_non_tax_rule("Employer retirement contribution", "employer_contribution"),
    "roth_retirement_employer" => standard_non_tax_rule("Employer Roth contribution", "employer_contribution"),
    "insurance_employee" => standard_non_tax_rule("Employee insurance deduction", "deduction")
  }.freeze

  def initialize(company:, effective_on:)
    @company = company
    @effective_on = effective_on
  end

  def call
    {
      "schema_version" => SCHEMA_VERSION,
      "effective_on" => effective_on.iso8601,
      "default_version" => DEFAULT_VERSION,
      "rules" => effective_rules.values.sort_by { |rule| rule.fetch("component_key") },
      "custom_payroll_fields" => custom_payroll_field_rules
    }
  end

  def rule_for(component_key)
    effective_rules[component_key.to_s]
  end

  private

  attr_reader :company, :effective_on

  def effective_rules
    @effective_rules ||= begin
      defaults = DEFAULT_RULES.to_h do |key, attrs|
        [ key, attrs.stringify_keys.merge(
          "id" => nil,
          "company_id" => nil,
          "component_key" => key,
          "effective_from" => Date.new(2020, 1, 1).iso8601,
          "effective_to" => nil,
          "version" => DEFAULT_VERSION,
          "source" => "application_default"
        ) ]
      end

      configured_rules.each_with_object(defaults) do |rule, merged|
        merged[rule.component_key] = rule.snapshot.merge("source" => "database")
      end
    end
  end

  def configured_rules
    PayComponentTaxRule.active
      .for_company_or_global(company.id)
      .effective_on(effective_on)
      .order(Arel.sql("company_id NULLS FIRST"), effective_from: :asc, id: :asc)
      .to_a
  end

  def custom_payroll_field_rules
    company.payroll_field_definitions.order(:id).map do |field|
      {
        "payroll_field_definition_id" => field.id,
        "name" => field.name,
        "kind" => field.kind,
        "tax_treatment" => field.tax_treatment,
        "category" => field.category,
        "reporting_group" => field.reporting_group,
        "payee_name" => field.payee_name,
        "active" => field.active
      }
    end
  end
end
