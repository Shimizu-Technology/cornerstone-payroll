# frozen_string_literal: true

require "bigdecimal"

module PayrollIntake
  # Validates and persists imported one-time PayrollItemFieldEntry components
  # across all intake adapters (MoSa Revel workbook and Cornerstone universal
  # workbook) so both apply paths enforce identical tax-treatment rules.
  class ComponentApplier
    EXPECTED_TREATMENTS = {
      "addition" => %w[taxable_addition non_taxable_addition].freeze,
      "deduction" => %w[pre_tax_deduction post_tax_deduction].freeze,
      "employer_contribution" => %w[employer_contribution].freeze
    }.freeze

    def initialize(pay_period:)
      @pay_period = pay_period
    end

    def apply!(payroll_item, components)
      normalized = Array(components).map { |component| validate!(component) }
      entries = payroll_item.payroll_item_field_entries
      # Destroy through the association so calculation sees only retained and replacement entries.
      entries.destroy(*entries.select { |entry| entry.source == "import" })
      normalized.each do |component|
        entries.build(
          company_id: pay_period.company_id,
          label: component.fetch(:label),
          kind: component.fetch(:kind),
          tax_treatment: component.fetch(:tax_treatment),
          category: component.fetch(:category),
          amount: component.fetch(:amount),
          employee_paid: component.fetch(:kind) != "employer_contribution",
          employer_paid: component.fetch(:kind) == "employer_contribution",
          reporting_group: component[:reporting_group],
          source: "import",
          notes: component[:notes],
          metadata: component.except(:label, :kind, :tax_treatment, :category, :amount, :reporting_group, :notes)
        )
      end
    end

    def validate!(component)
      data = component.to_h.with_indifferent_access
      amount = decimal_or_zero(data[:amount])
      kind = data[:kind].to_s
      treatment = data[:tax_treatment].to_s
      category = data[:category].to_s
      component_type = data[:component_type].to_s
      rule = PayrollImport::LoanTipExcelParser::GENERATED_COMPONENT_TYPES[component_type]
      raise ArgumentError, "Imported component label is required." if data[:label].to_s.strip.blank?
      raise ArgumentError, "Imported component amount must be positive." unless amount.positive?
      raise ArgumentError, "Imported component type is invalid." unless rule
      raise ArgumentError, "Imported component kind is invalid." unless PayrollFieldDefinition::KINDS.include?(kind)
      raise ArgumentError, "Imported component tax treatment is invalid." unless PayrollFieldDefinition::TAX_TREATMENTS.include?(treatment)
      raise ArgumentError, "Imported component category is invalid." unless PayrollFieldDefinition::CATEGORIES.include?(category)
      unless kind == rule.fetch(:kind) && treatment == rule.fetch(:tax_treatment)
        raise ArgumentError, "Imported component type and tax treatment conflict."
      end
      raise ArgumentError, "Loan and retirement changes must use their dedicated Cornerstone setup." if category.in?(%w[loan retirement])
      raise ArgumentError, "Imported component source or reason is required." if data[:source].to_s.strip.blank?
      unless iso_date(data[:effective_pay_date]) == pay_period.pay_date
        raise ArgumentError, "Imported components must use this payroll's pay date."
      end
      if kind.in?(%w[deduction employer_contribution]) && data[:payee_name].to_s.strip.blank?
        raise ArgumentError, "Imported deduction and employer contribution components require a payee."
      end
      unless EXPECTED_TREATMENTS.fetch(kind).include?(treatment)
        raise ArgumentError, "Imported component type and tax treatment conflict."
      end

      {
        label: data[:label].to_s.strip,
        amount: amount,
        kind: kind,
        tax_treatment: treatment,
        category: category,
        reporting_group: PayrollReportingGroups.normalize(data[:reporting_group]),
        payee_name: data[:payee_name].to_s.strip.presence,
        effective_pay_date: data[:effective_pay_date].to_s,
        source: data[:source].to_s.strip,
        notes: data[:notes].to_s.strip.presence,
        component_type: component_type
      }
    end

    private

    attr_reader :pay_period

    def decimal_or_zero(value)
      BigDecimal(value.to_s.presence || "0").round(2)
    rescue ArgumentError
      0.to_d
    end

    def iso_date(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
  end
end
