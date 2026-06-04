# frozen_string_literal: true

# Shared reporting buckets used to place flexible payroll fields and deductions
# into QuickBooks-style report sections without guessing from arbitrary labels.
module PayrollReportingGroups
  GROUP_401K_PRE_TAX = "401k_pre_tax"
  GROUP_401K_AFTER_TAX = "401k_after_tax"
  GROUP_RETIREMENT_OTHER = "retirement_other"

  GROUPS = [
    GROUP_401K_PRE_TAX,
    GROUP_401K_AFTER_TAX,
    GROUP_RETIREMENT_OTHER
  ].freeze

  LABELS = {
    GROUP_401K_PRE_TAX => "401(k) Pre-Tax",
    GROUP_401K_AFTER_TAX => "401(k) After Tax",
    GROUP_RETIREMENT_OTHER => "Other Retirement"
  }.freeze

  TYPE_LABELS = {
    GROUP_401K_PRE_TAX => "401(k)",
    GROUP_401K_AFTER_TAX => "SIMPLE 401(k)",
    GROUP_RETIREMENT_OTHER => "Retirement Plan"
  }.freeze

  module_function

  def normalize(group)
    value = group.to_s.presence
    GROUPS.include?(value) ? value : nil
  end

  def label(group)
    LABELS.fetch(normalize(group), nil)
  end

  def type_label(group)
    TYPE_LABELS.fetch(normalize(group), nil)
  end

  def retirement_group?(group)
    normalize(group).present?
  end

  # Only infers a 401(k) bucket from explicit retirement context or recognized
  # 401(k)/Roth labels. Arbitrary payroll fields are not classified.
  def infer_retirement_group(label:, category: nil, tax_treatment: nil, deduction_category: nil, explicit_group: nil)
    explicit = normalize(explicit_group)
    return explicit if explicit

    label_text = label.to_s
    retirement_context = category.to_s == "retirement"
    recognized_401k_label = label_text.match?(/401\s*\(?k\)?/i)
    roth_or_after_tax_label = label_text.match?(/roth|after[-\s]?tax/i)
    return nil unless retirement_context || recognized_401k_label

    if roth_or_after_tax_label || tax_treatment.to_s == "post_tax_deduction" || deduction_category.to_s == "post_tax"
      return GROUP_401K_AFTER_TAX if recognized_401k_label || (retirement_context && roth_or_after_tax_label)
      return GROUP_RETIREMENT_OTHER
    end

    if recognized_401k_label || label_text.match?(/pre[-\s]?tax/i)
      GROUP_401K_PRE_TAX
    else
      GROUP_RETIREMENT_OTHER
    end
  end
end
