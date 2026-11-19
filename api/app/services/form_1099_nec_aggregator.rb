# frozen_string_literal: true

# Form1099NecAggregator
#
# Produces annual 1099-NEC summary data from committed payroll for contractors.
#
# IRS Form 1099-NEC reports nonemployee compensation paid to independent
# contractors. Reporting thresholds are selected by payment year from the
# versioned InformationReturnThreshold table.
#
# Box 1: Nonemployee compensation (total gross payments)
# Box 4: Federal income tax withheld (typically $0 unless backup withholding)
#
class Form1099NecAggregator
  attr_reader :company, :year, :threshold_rule

  def initialize(company, year)
    @company = company
    @year = year.to_i
    @threshold_rule = InformationReturnThreshold.for!(form_type: "1099_nec", tax_year: @year)
  end

  def generate
    rows = contractors.map { |contractor| contractor_row(contractor) } + standalone_contractor_rows
    reportable = rows.select { |r| r[:total_compensation] >= filing_threshold }

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
          "One-off contractor checks are grouped by exact payee name. They have no worker/TIN link; reconcile identity with payroll contractors before filing.",
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
        total_federal_withheld: rows.sum(0.to_d) { |r| r[:federal_withheld].to_d }.round(2).to_f
      }
    }
  end

  private

  def filing_threshold
    threshold_rule.threshold_amount.to_d
  end

  def contractors
    @contractors ||= Employee
      .where(company_id: company.id, id: aggregated_items.keys)
      .order(:last_name, :first_name)
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
  def standalone_contractor_checks
    @standalone_contractor_checks ||= year_contractor_checks.select { |check| check.printed_at.present? || check.paid_at.present? }
  end

  def year_contractor_checks
    @year_contractor_checks ||= company.non_employee_checks.active.where(check_type: "contractor").includes(:pay_period)
      .select { |check| (Date.new(year, 1, 1)..Date.new(year, 12, 31)).cover?(check.effective_payment_date) }
  end

  def unissued_contractor_check_note
    unissued = year_contractor_checks.length - standalone_contractor_checks.length
    unissued.positive? ? [ "#{unissued} contractor check(s) dated #{year} are not printed or paid yet and are not counted." ] : []
  end

  def contractor_row(contractor)
    sums = aggregated_items[contractor.id]
    total_comp = sums&.total_gross.to_f
    withheld = sums&.total_withheld.to_f

    compliance_issues = []
    compliance_issues << "Missing SSN/TIN" unless contractor.valid_filing_ssn? || contractor.contractor_ein.present?
    compliance_issues << "Missing address" if contractor.address_line1.blank?
    compliance_issues << "W-9 not on file" unless contractor.w9_on_file?
    compliance_issues << "Below filing threshold ($#{filing_threshold.to_f})" if total_comp < filing_threshold

    {
      employee_id: contractor.id,
      name: contractor.full_name,
      business_name: contractor.business_name,
      contractor_type: contractor.contractor_type,
      tin_type: contractor.contractor_type == "business" && contractor.contractor_ein.present? ? "EIN" : "SSN",
      tin_last_four: if contractor.contractor_type == "business" && contractor.contractor_ein.present?
                       contractor.contractor_ein.last(4)
                     else
                       contractor.ssn_last_four
                     end,
      address: contractor.full_address,
      total_compensation: total_comp.round(2),
      federal_withheld: withheld.round(2),
      payment_count: sums&.payment_count.to_i,
      requires_filing: total_comp >= filing_threshold,
      w9_on_file: contractor.w9_on_file?,
      compliance_issues: compliance_issues
    }
  end
end
