# frozen_string_literal: true

# Read-only compatibility for retained pre-tracking calculations and postings.
# This records old omissions; it never creates a payable or repairs old money.
class PayrollLegacyEmployerComponents
  POSTING_VERSION_KEY = "employer_contribution_ledger_version".freeze

  def self.eligible?(item)
    context = item.calculation_context_snapshot.to_h
    return false unless item.persisted? && item.pay_period.committed? && PayrollCalculationContext.valid_for_correction?(context)
    return false if context.key?("built_in_employer_match_mirrors") || context.key?("corrective_paycheck")

    postings = item.pay_period.payroll_liability_postings.to_a
    postings.any? && postings.none? { |posting| posting.metadata.to_h.key?(POSTING_VERSION_KEY) }
  end

  def self.field_mirror?(item, field, row)
    return false unless row.deduction_type&.company_id == item.company_id
    return false unless eligible?(item) && field.employer_contribution?
    return false if PayrollComponentMirrors.independent_type_ids(item).include?(row.deduction_type_id)
    return false unless row.deduction_type&.name == field.label && row.deduction_type.category == "employer_contribution"
    return false unless row.deduction_type.sub_category == field.category
    return false unless item.payroll_item_field_entries.count { |entry| entry.active? && entry.label == field.label && entry.tax_treatment == field.tax_treatment } == 1

    assignments = item.calculation_context_snapshot["payroll_field_assignments"]
    return false unless assignments.is_a?(Array) && assignments.all? { |assignment| assignment.is_a?(Hash) && assignment["definition"].is_a?(Hash) }

    definitions = assignments.map { |assignment| assignment.fetch("definition") }
    definitions.count do |definition|
      definition["id"] == field.payroll_field_definition_id && definition["company_id"] == item.company_id &&
        definition["name"] == field.label && definition["kind"] == field.kind && definition["tax_treatment"] == field.tax_treatment &&
        definition["category"] == field.category && PayrollReportingGroups.normalize(definition["reporting_group"]) == PayrollReportingGroups.normalize(field.reporting_group)
    end == 1
  end

  def self.built_in_mirror?(item, row, field)
    row.deduction_type&.company_id == item.company_id && eligible?(item) && row.deduction_type.name == row.label && row.amount.to_d == item.public_send(field).to_d &&
      item.payroll_item_field_entries.none? { |entry| entry.active? && entry.label == row.label }
  end

  def self.omissions(item, expected, posted)
    return unless eligible?(item)

    # A partial, unexpected or incorrectly valued source is never an old-rule omission.
    return unless posted.all? { |key, amount| expected[key] == amount }

    fields = item.payroll_item_field_entries.select { |field| field.active? && field.employer_contribution? }
    mirrors = PayrollComponentMirrors.resolution(item).keys.to_set
    omitted = {}
    fields.each do |field|
      next if PayrollLiabilityPostingService::FIELD_CATEGORY_MAP.key?(field.category)

      omitted["payroll_field:#{field.payroll_field_definition_id || 'snapshot'}:#{field.id}"] = [ field.label, "Employer field category was not posted by the legacy rules" ]
    end
    item.payroll_item_deductions.each do |row|
      next unless row.employer_contribution? && !mirrors.include?(row.deduction_type_id)
      next if PayrollRetirementTotals.built_in_employer_match_deduction?(item, row)
      next if deduction_subcategory(item, row).in?(%w[retirement garnishment child_support benefit]) &&
        item.payroll_item_field_entries.none? { |field| field.label == row.label }

      omitted["deduction_type:#{row.deduction_type_id}:#{row.id}"] = [ row.label, "Employer deduction was excluded by the legacy posting rules" ]
    end
    missing = expected.except(*posted.keys)
    return unless missing.keys.all? { |key| omitted.key?(key) }

    missing.map do |key, amount|
      label, reason = omitted.fetch(key)
      { "payroll_item_id" => item.id, "component_key" => key, "label" => label, "amount" => amount.to_s("F"),
        "reason" => reason, "source_posting_ids" => item.pay_period.payroll_liability_postings.order(:id).pluck(:id) }
    end
  end

  def self.category_for(item, key, legacy:)
    if key.start_with?("payroll_field:")
      field = item.payroll_item_field_entries.find { |row| key.end_with?(":#{row.id}") }
      category = field&.category
      return PayrollLiabilityPostingService::FIELD_CATEGORY_MAP[category]&.first&.sub("_employee", "_employer") if legacy
    elsif key.start_with?("deduction_type:")
      row = item.payroll_item_deductions.find { |deduction| key == "deduction_type:#{deduction.deduction_type_id}:#{deduction.id}" }
      category = legacy && row ? deduction_subcategory(item, row) : row&.deduction_type&.sub_category
      return category if legacy && category.in?(%w[garnishment child_support])
    else
      return key.sub("employer_retirement_match", "retirement_employer").sub("employer_roth_retirement_match", "roth_retirement_employer")
    end
    case category
    when "retirement" then "retirement_employer"
    when "insurance", "benefit" then "benefit_employer"
    else "other_payroll_liability"
    end
  end

  def self.deduction_subcategory(item, row)
    source = Array(item.calculation_context_snapshot["employee_deductions"]).find do |assignment|
      assignment.is_a?(Hash) && assignment.dig("deduction_type", "id") == row.deduction_type_id
    end
    source ? source.dig("deduction_type", "sub_category") : row.deduction_type&.sub_category
  end

  def self.verify_posting_shape!(item)
    expected = {}
    PayrollLiabilityPostingService::CORE_COMPONENTS.each do |key, (field, category, _authority)|
      amount = item.public_send(field).to_d
      amount -= item.additional_medicare_tax.to_d if key == "medicare_employee"
      expected[[ key, category ]] = amount.round(2) if amount.nonzero?
    end
    fields = item.payroll_item_field_entries.to_a
    fields.each do |field|
      next unless field.active? && field.kind.in?(%w[deduction employer_contribution]) && field.amount.to_d.nonzero?
      category = PayrollLiabilityPostingService::FIELD_CATEGORY_MAP[field.category]&.first
      next unless category

      category = category.sub("_employee", "_employer") if field.employer_contribution?
      expected[[ "payroll_field:#{field.payroll_field_definition_id || 'snapshot'}:#{field.id}", category ]] = field.amount.to_d.round(2)
    end
    item.payroll_item_deductions.each do |row|
      subcategory = deduction_subcategory(item, row)
      next unless subcategory.in?(%w[retirement garnishment child_support benefit]) && row.amount.to_d.nonzero?
      next if fields.any? { |field| field.label == row.label } || PayrollRetirementTotals.built_in_employer_match_deduction?(item, row)

      category = subcategory.in?(%w[retirement benefit]) ? "#{subcategory}_#{row.employer_contribution? ? 'employer' : 'employee'}" : subcategory
      expected[[ "deduction_type:#{row.deduction_type_id}:#{row.id}", category ]] = row.amount.to_d.round(2)
    end
    actual = PayrollLiabilityEntry.where(payroll_item_id: item.id).each_with_object(Hash.new(0.to_d)) do |entry, totals|
      totals[[ entry.component_key, entry.category ]] += entry.amount.to_d
    end.reject { |_key, amount| amount.zero? }
    return if expected == actual

    raise PayrollLiabilityPostingService::InvalidStateError, "Saved employer contribution history does not reconcile to the retained legacy posting rules; arrange a reviewed benefit-ledger correction"
  end

  def self.evidence(item)
    return unless eligible?(item)

    postings = item.pay_period.payroll_liability_postings.order(:id).map do |posting|
      { posting: posting.attributes, entries: posting.entries.order(:id).map(&:attributes) }
    end
    { "payroll_item_id" => item.id, "source_posting_ids" => postings.map { |row| row[:posting].fetch("id") },
      "evidence_digest" => Digest::SHA256.hexdigest(JSON.generate(postings.as_json)),
      "legacy_insurance_classification" => (item.insurance_payment.to_d - PayrollInsuranceComponents.scalar_amount(item)).to_s("F") }
  end
end
