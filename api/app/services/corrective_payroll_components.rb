# frozen_string_literal: true

# Materializes target - (original + active supplementals) using saved component
# identities. No historical row is edited and no current employee setup is read.
class CorrectivePayrollComponents
  Error = IssueCorrectivePaycheckService::CorrectionError
  FIELD_ATTRIBUTES = %w[payroll_field_definition_id label kind tax_treatment category employee_paid employer_paid reporting_group active source notes metadata].freeze
  DEDUCTION_ATTRIBUTES = %w[deduction_type_id category label reporting_group employee_loan_id loan_schedule_snapshot].freeze
  EARNING_ATTRIBUTES = %w[category label rate hours].freeze

  def initialize(original:, corrected:, active:)
    unsupported = active.reject do |item|
      item.calculation_context_snapshot.to_h.dig("corrective_paycheck", "component_ledger_version") == 1
    end
    if unsupported.any?
      raise Error, "An active corrective paycheck predates or uses an unsupported component ledger (items #{unsupported.map(&:id).join(', ')}). Arrange a reviewed component-ledger reconciliation before issuing another correction; legacy components cannot be reconstructed automatically"
    end
    @original = original
    @corrected = corrected
    @recorded = [ original, *active ]
  end

  def apply!(item)
    deduction_rows.each { |row| item.payroll_item_deductions.build(row) }
    field_rows.each { |row| item.payroll_item_field_entries.build(row) }
    earning_rows.each { |row| item.payroll_item_earnings.build(row) }
    item.custom_earnings = json_deltas(:custom_earnings, %w[label])
    item.custom_deductions = json_deltas(:custom_deductions, %w[label])
    item.payroll_adjustments = json_deltas(:active_payroll_adjustments, %w[label treatment notes])
    # These are disclosure/source flags, never the absolute target's monetary
    # custom columns (or wage-rate hours, which would repeat historical hours).
    item.custom_columns_data = @corrected.custom_columns_data.to_h.slice(
      PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY, "payroll_adjustments_overridden", PayrollItem::CUSTOM_EARNINGS_SOURCE_KEY
    )
    validate_loans!(item)
    validate_detail!(item)
  end

  def snapshot
    {
      deductions: deduction_rows, fields: field_rows, earnings: earning_rows,
      custom_earnings: json_deltas(:custom_earnings, %w[label]),
      custom_deductions: json_deltas(:custom_deductions, %w[label]),
      payroll_adjustments: json_deltas(:active_payroll_adjustments, %w[label treatment notes])
    }
  end

  private

  def deduction_rows
    rows_for(:payroll_item_deductions, DEDUCTION_ATTRIBUTES, ->(row) { row.deduction_type_id }) do |item, row|
      !PayrollRetirementTotals.built_in_employer_match_deduction?(item, row)
    end
  end

  def field_rows
    rows_for(:payroll_item_field_entries, FIELD_ATTRIBUTES, ->(row) {
      row.payroll_field_definition_id || row.attributes.slice(*FIELD_ATTRIBUTES.excluding("metadata", "notes", "active"))
    }) { |_item, row| row.active? }
  end

  def earning_rows
    rows_for(:payroll_item_earnings, EARNING_ATTRIBUTES, ->(row) { [ row.category, row.label ] }, earnings: true)
  end

  def rows_for(association, attributes, identity, earnings: false)
    grouped = {}
    [ [ @corrected, 1 ], *@recorded.map { |item| [ item, -1 ] } ].each do |item, sign|
      seen = Set.new
      item.public_send(association).each do |row|
        next if block_given? && !yield(item, row)
        key = identity.call(row)
        raise Error, "Ambiguous #{association} identity; review the component history before correcting this paycheck" unless seen.add?(key)

        attrs = row.attributes.slice(*attributes).deep_dup
        if association == :payroll_item_deductions && item.equal?(@corrected) && row.deduction_type&.loan?
          # Historical recomputation deliberately does not resolve a live loan.
          # Retain only the original identity so an unchanged fixed payment
          # produces no delta. Any changed amount is held below, never applied.
          original_row = @original.payroll_item_deductions.find { |entry| entry.deduction_type_id == row.deduction_type_id }
          attrs["employee_loan_id"] = original_row&.employee_loan_id
        end
        group = grouped[key] ||= { attributes: attrs, amount: 0.to_d, hours: 0.to_d, rates: Set.new }
        unless earnings || same_identity?(group[:attributes], attrs)
          raise Error, "A #{association} identity changed; review its reporting and mirror history before correcting this paycheck"
        end
        group[:amount] += sign * row.amount.to_d
        if earnings
          group[:hours] += sign * row.hours.to_d
          group[:rates].add(row.rate)
        end
      end
    end
    grouped.values.filter_map do |group|
      amount = group[:amount].round(2)
      next if amount.zero? && (!earnings || group[:hours].zero?)

      attrs = group[:attributes].merge("amount" => amount)
      if earnings
        attrs["hours"] = group[:hours].zero? ? nil : group[:hours]
        # A rate-change adjustment has money even with no extra hours. A nil
        # rate states this honestly instead of multiplying by the old rate.
        attrs["rate"] = group[:rates].one? ? group[:rates].first : nil
      end
      attrs
    end
  end

  def same_identity?(left, right)
    left.except("metadata", "notes", "loan_schedule_snapshot") == right.except("metadata", "notes", "loan_schedule_snapshot")
  end

  def json_deltas(method, identity_fields)
    grouped = {}
    [ [ @corrected, 1 ], *@recorded.map { |item| [ item, -1 ] } ].each do |item, sign|
      Array(item.public_send(method)).each do |entry|
        attrs = entry.stringify_keys.slice(*identity_fields)
        key = attrs.to_a.sort
        row = grouped[key] ||= attrs.merge("amount" => 0.to_d)
        row["amount"] += sign * entry.fetch("amount").to_d
      end
    end
    grouped.values.filter_map do |row|
      amount = row.fetch("amount").round(2)
      row.merge("amount" => amount.to_f) unless amount.zero?
    end
  end

  def validate_loans!(item)
    changed = item.loan_payment.to_d.nonzero? || item.payroll_item_deductions.any? { |row| row.deduction_type&.loan? } ||
      item.payroll_item_field_entries.any? { |row| row.category == "loan" }
    return unless changed

    raise Error, "A changed loan component requires a reviewed loan-ledger correction; this supplemental cannot apply or reverse loan transactions"
  end

  def validate_detail!(item)
    [ *item.payroll_item_deductions, *item.payroll_item_field_entries, *item.payroll_item_earnings ].each do |row|
      raise Error, "The corrective component cannot be represented: #{row.errors.full_messages.join(', ')}" unless row.valid?
    end
    unless item.insurance_payment.to_d == PayrollInsuranceComponents.scalar_amount(item) &&
        PayrollInsuranceComponents.total(item) == PayrollInsuranceComponents.total(@corrected) - @recorded.sum { |record| PayrollInsuranceComponents.total(record) }
      raise Error, "Corrective insurance classification does not reconcile with its liability components"
    end
    data = QuickbooksPayrollReportData.new(item.pay_period)
    employer = employer_contributions(item)
    expected_employer = employer_contributions(@corrected) - @recorded.sum { |record| employer_contributions(record) }
    unless employer.round(2) == expected_employer.round(2)
      raise Error, "The corrective employer contribution detail does not reconcile to the remaining target; review the saved contribution history before posting liabilities"
    end
    earnings = data.earnings_lines_for(item).reject { |line| line.label == "Gross" }.sum { |line| line.amount.to_d }
    deductions = data.employee_tax_total(item).to_d +
      data.pre_tax_retirement_deduction_lines_for(item).sum { |line| line.amount.to_d } +
      data.after_tax_deduction_lines_for(item).sum { |line| line.amount.to_d }
    other = data.other_pay_lines_for(item).sum { |line| line.amount.to_d }
    additions = item.reported_tips.to_d + item.service_charge_wages.to_d + item.bonus.to_d +
      Array(item.custom_earnings).sum { |row| row.fetch("amount").to_d } + item.taxable_payroll_adjustments_total.to_d +
      item.taxable_payroll_field_entries_total.to_d + other
    unless additions.round(2) == item.total_additions.to_d.round(2) && earnings.round(2) == item.gross_pay.to_d.round(2) && deductions.round(2) == item.total_deductions.to_d.round(2) &&
        (item.gross_pay.to_d + other - deductions).round(2) == item.net_pay.to_d.round(2)
      raise Error, "The corrective component detail does not reconcile to gross, deductions and net pay; review the saved earning and deduction history"
    end
  end

  def employer_contributions(item)
    PayrollEmployerContributions.total(item)
  end
end
