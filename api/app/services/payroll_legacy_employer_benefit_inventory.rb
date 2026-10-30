# frozen_string_literal: true

# Candidate counts only: these are not reconciled liabilities or permission to
# backfill source identities. Includes instrument-voided and reversed history.
class PayrollLegacyEmployerBenefitInventory
  def self.call
    connection = ApplicationRecord.connection
    if connection.transaction_open?
      raise ArgumentError, "Legacy benefit inventory requires a read-only transaction" unless connection.select_value("SHOW transaction_read_only") == "on"

      return inventory
    end

    connection.transaction(isolation: :repeatable_read) do
      connection.execute("SET TRANSACTION READ ONLY")
      inventory
    end
  end

  def self.inventory
    groups = {}
    PayrollItem.joins(:pay_period).where(pay_periods: { status: "committed" })
      .includes(:pay_period, :company, { payroll_item_field_entries: :payroll_field_definition }, payroll_item_deductions: :deduction_type).find_each do |item|
      next if qualifying_postings?(item.pay_period)

      fields = item.payroll_item_field_entries.select do |field|
        field.active? && field.employer_contribution? && field.amount.to_d.nonzero? &&
          field.metadata.to_h[PayrollComponentMirrors::IDENTITY_KEY].nil?
      end
      tracked_type_ids = item.payroll_item_field_entries.filter_map do |field|
        field.metadata.to_h.dig(PayrollComponentMirrors::IDENTITY_KEY, "deduction_type_id")
      end
      deductions = item.payroll_item_deductions.select do |row|
        row.employer_contribution? && row.amount.to_d.nonzero? && !tracked_type_ids.include?(row.deduction_type_id)
      end
      next if fields.empty? && deductions.empty?

      key = [ item.company_id, item.pay_period.pay_date.year ]
      group = groups[key] ||= { company_id: item.company_id, company_name: item.company.name,
        year: key.last, payroll_items: 0, employee_ids: Set.new, employer_field_rows: 0, employer_deduction_rows: 0,
        instrument_voided_items: 0, report_compatible_review_items: 0, ambiguous_items: 0 }
      group[:payroll_items] += 1
      group[:employee_ids] << item.employee_id
      group[:employer_field_rows] += fields.length
      group[:employer_deduction_rows] += deductions.length
      group[:instrument_voided_items] += 1 if item.voided?
      begin
        group[:report_compatible_review_items] += 1 if PayrollReportComponentReview.for_item(item).any?
      rescue PayrollComponentMirrors::AmbiguousHistoryError
        group[:ambiguous_items] += 1
      end
    end
    rows = groups.sort_by { |key, _group| key }.map do |_key, group|
      group.except(:employee_ids).merge(employees: group[:employee_ids].size)
    end
    { mode: "read_only_inventory", scope: "committed saved employer fields/deductions without mirror metadata or qualifying postings",
      company_years: rows }
  end
  private_class_method :inventory

  def self.qualifying_postings?(period)
    postings = period.payroll_liability_postings.order(:id).to_a
    postings.any? && postings.none? do |posting|
      PayrollLegacyEmployerComponents::INELIGIBLE_POSTING_KEYS.any? { |key| posting.metadata.to_h.key?(key) }
    end
  end
  private_class_method :qualifying_postings?
end
