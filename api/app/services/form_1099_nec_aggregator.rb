# frozen_string_literal: true

# Form1099NecAggregator
#
# Produces annual 1099-NEC summary data from committed payroll for contractors.
#
# IRS Form 1099-NEC reports nonemployee compensation paid to independent
# contractors. Reporting thresholds are selected by payment year from the
# versioned InformationReturnThreshold table.
#
# Box 1: Nonemployee compensation (total gross payments, plus any one-off
#        contractor checks linked to the contractor from the year-end checklist)
# Box 4: Federal income tax withheld (typically $0 unless backup withholding)
#
class Form1099NecAggregator
  attr_reader :company, :year, :threshold_rule

  # Reportable contractor records that share one TIN, each group sorted by
  # name. Each would get its own 1099, which sends two to one payee.
  def self.duplicate_tin_groups(employees)
    employees.filter_map { |employee| [ employee.form_1099_tin, employee ] if employee.form_1099_tin }
      .group_by(&:first).values.select { |group| group.length > 1 }
      .map { |group| group.map(&:last).sort_by { |employee| [ employee.last_name.to_s.downcase, employee.first_name.to_s.downcase, employee.id ] } }
      .sort_by { |group| group.first.id }
  end

  def initialize(company, year)
    @company = company
    @year = year.to_i
    @threshold_rule = InformationReturnThreshold.for!(form_type: "1099_nec", tax_year: @year)
  end

  def generate
    rows = contractors.map { |contractor| contractor_row(contractor) } + standalone_contractor_rows
    reportable = rows.select { |r| r[:requires_filing] }

    {
      meta: {
        report_type: "1099_nec",
        company_id: company.id,
        company_name: company.name,
        year: year,
        generated_at: Time.current.iso8601,
        contractor_count: rows.length,
        reportable_count: reportable.length,
        filing_threshold: filing_threshold,
        filing_threshold_rule_id: threshold_rule.id,
        filing_threshold_source_url: threshold_rule.source_url,
        caveats: [
          "This report is a preparation summary and should be reviewed before filing.",
          "The configured #{year} filing threshold is $#{filing_threshold.to_f}.",
          "Verify TIN/SSN for each contractor before filing.",
          "One-off contractor checks linked to a contractor record count toward that contractor. Unlinked ones are grouped by exact payee name and have no TIN; resolve them in the year-end checklist before filing.",
          *unissued_contractor_check_note,
          "Box 1 = Total gross payments to contractor during the tax year.",
          "Box 4 = Federal income tax withheld (typically $0 for contractors without backup withholding)."
        ]
      },
      payer: {
        name: company.name,
        ein: company.ein,
        address: [ company.address_line1, company.address_line2 ].compact_blank.join(", "),
        city_state_zip: [ company.city, company.state, company.zip ].compact_blank.join(", ")
      },
      all_contractors: rows,
      reportable_contractors: reportable,
      totals: {
        total_compensation: rows.sum(0.to_d) { |r| r[:total_compensation].to_d }.round(2).to_f,
        reportable_compensation: reportable.sum(0.to_d) { |r| r[:total_compensation].to_d }.round(2).to_f,
        reportable_federal_withheld: reportable.sum(0.to_d) { |r| r[:federal_withheld].to_d }.round(2),
        total_federal_withheld: rows.sum(0.to_d) { |r| r[:federal_withheld].to_d }.round(2)
      }
    }
  end

  private

  def filing_threshold
    threshold_rule.threshold_amount.to_d
  end

  def contractors
    @contractors ||= Employee
      .where(company_id: company.id, id: (aggregated_items.keys + linked_checks.keys).uniq)
      .order(:last_name, :first_name, :id)
  end

  # Issued one-off checks staff linked to a contractor record, by contractor.
  def linked_checks
    @linked_checks ||= issued_contractor_checks.select(&:payee_employee_id).group_by(&:payee_employee_id)
  end

  def aggregated_items
    @aggregated_items ||= PayrollItem
      .joins(:pay_period)
      .where(company_id: company.id, employment_type: "contractor")
      .financially_reportable
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company.id, pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
          .select(:id)
      })
      .group(:employee_id)
      .select(
        "employee_id",
        "SUM(gross_pay) AS total_gross",
        "SUM(COALESCE(withholding_tax, 0)) AS total_withheld",
        "COUNT(*) AS payment_count"
      )
      .index_by(&:employee_id)
  end

  def standalone_contractor_rows
    # No employee/TIN foreign key exists on these checks. Do not silently merge
    # people by display name. Preserve the amounts and flag identity resolution.
    standalone_contractor_checks.group_by(&:payable_to).map do |name, payments|
      total = payments.sum(0.to_d, &:amount).round(2)
      issues = [ "Missing SSN/TIN", "Missing address", "W-9 not on file",
        "One-off contractor payee has no worker/TIN link; reconcile with payroll contractor payments before filing" ]
      issues << "Below filing threshold ($#{filing_threshold.to_f})" if total < filing_threshold
      {
        employee_id: nil,
        payee_key: "non_employee_check:#{payments.map(&:id).min}",
        non_employee_check_ids: payments.map(&:id).sort,
        name: name, business_name: nil, contractor_type: nil, tin_type: "Unknown",
        tin_last_four: nil, address: nil, total_compensation: total.to_f,
        federal_withheld: 0.0, payment_count: payments.length,
        requires_filing: total >= filing_threshold, w9_on_file: false,
        compliance_issues: issues
      }
    end
  end

  # Only checks that were printed or paid count; an unissued draft is not a payment.
  def issued_contractor_checks
    @issued_contractor_checks ||= year_contractor_checks.select { |check| check.printed_at.present? || check.paid_at.present? }
  end

  # Issued checks not linked to a contractor record.
  def standalone_contractor_checks
    @standalone_contractor_checks ||= issued_contractor_checks.reject(&:payee_employee_id)
  end

  def year_contractor_checks
    @year_contractor_checks ||= company.non_employee_checks.active.where(check_type: "contractor").includes(:pay_period)
      .select { |check| (Date.new(year, 1, 1)..Date.new(year, 12, 31)).cover?(check.effective_payment_date) }
  end

  def unissued_contractor_check_note
    unissued = year_contractor_checks.length - issued_contractor_checks.length
    unissued.positive? ? [ "#{unissued} contractor check(s) dated #{year} are not printed or paid yet and are not counted." ] : []
  end

  def contractor_row(contractor)
    sums = aggregated_items[contractor.id]
    checks = Array(linked_checks[contractor.id]).sort_by(&:id)
    # BigDecimal for the threshold checks; a JSON number only in the row.
    total_comp = (sums&.total_gross.to_d + checks.sum(0.to_d) { |check| check.amount.to_d }).round(2)
    withheld = sums&.total_withheld.to_d

    compliance_issues = []
    tin = contractor.form_1099_tin
    compliance_issues << "Missing SSN/TIN" unless tin
    compliance_issues << "Missing address" if contractor.address_line1.blank?
    compliance_issues << "W-9 not on file" unless contractor.w9_on_file?
    compliance_issues << "Below filing threshold ($#{filing_threshold.to_f})" if total_comp < filing_threshold && withheld.zero?

    {
      employee_id: contractor.id,
      name: contractor.full_name,
      business_name: contractor.business_name,
      contractor_type: contractor.contractor_type,
      tin_type: tin ? tin[:type] : (contractor.business_contractor? ? "EIN" : "SSN"),
      tin_last_four: tin&.dig(:digits)&.last(4),
      address: contractor.full_address,
      total_compensation: total_comp.to_f,
      federal_withheld: withheld.round(2),
      payment_count: sums&.payment_count.to_i + checks.length,
      payroll_payment_count: sums&.payment_count.to_i,
      non_employee_check_ids: checks.map(&:id),
      requires_filing: total_comp >= filing_threshold || !withheld.zero?,
      filing_reason: total_comp >= filing_threshold ? "filing threshold reached" : ("tax withheld" unless withheld.zero?),
      w9_on_file: contractor.w9_on_file?,
      compliance_issues: compliance_issues
    }
  end
end
