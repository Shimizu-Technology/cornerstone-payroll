# frozen_string_literal: true

# Form1099NecAggregator
#
# Produces annual 1099-NEC summary data from committed payroll for contractors.
#
# IRS Form 1099-NEC reports nonemployee compensation paid to independent
# contractors. A 1099-NEC must be filed for each contractor paid $600 or
# more during the tax year.
#
# Box 1: Nonemployee compensation (total gross payments)
# Box 4: Federal income tax withheld (typically $0 unless backup withholding)
#
class Form1099NecAggregator
  FILING_THRESHOLD = 600.00

  attr_reader :company, :year

  def initialize(company, year)
    @company = company
    @year = year.to_i
  end

  def generate
    rows = contractors.map { |contractor| contractor_row(contractor) }
    reportable = rows.select { |r| r[:total_compensation] >= FILING_THRESHOLD }

    {
      meta: {
        report_type: "1099_nec",
        company_id: company.id,
        company_name: company.name,
        year: year,
        generated_at: Time.current.iso8601,
        contractor_count: rows.length,
        reportable_count: reportable.length,
        filing_threshold: FILING_THRESHOLD,
        caveats: [
          "This report is a preparation summary and should be reviewed before filing.",
          "Only contractors with total compensation >= $#{FILING_THRESHOLD} require a 1099-NEC filing.",
          "Verify TIN/SSN for each contractor before filing.",
          "Box 1 = Total gross payments to contractor during the tax year.",
          "Box 4 = Federal income tax withheld (typically $0 for contractors without backup withholding)."
        ]
      },
      payer: {
        name: company.name,
        ein: company.ein,
        address: [company.address_line1, company.address_line2].compact_blank.join(", "),
        city_state_zip: [company.city, company.state, company.zip].compact_blank.join(", ")
      },
      all_contractors: rows,
      reportable_contractors: reportable,
      totals: {
        total_compensation: rows.sum { |r| r[:total_compensation] },
        reportable_compensation: reportable.sum { |r| r[:total_compensation] },
        total_federal_withheld: rows.sum { |r| r[:federal_withheld] }
      }
    }
  end

  private

  def contractors
    @contractors ||= Employee
      .where(company_id: company.id, employment_type: "contractor")
      .where(id: aggregated_items.keys)
      .order(:last_name, :first_name)
  end

  def aggregated_items
    @aggregated_items ||= PayrollItem
      .joins(:pay_period)
      .where(company_id: company.id, employment_type: "contractor")
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

  def contractor_row(contractor)
    sums = aggregated_items[contractor.id]
    total_comp = sums&.total_gross.to_f
    withheld = sums&.total_withheld.to_f

    compliance_issues = []
    compliance_issues << "Missing SSN/TIN" unless contractor.valid_filing_ssn? || contractor.contractor_ein.present?
    compliance_issues << "Missing address" if contractor.address_line1.blank?
    compliance_issues << "W-9 not on file" unless contractor.w9_on_file?
    compliance_issues << "Below filing threshold ($#{FILING_THRESHOLD})" if total_comp < FILING_THRESHOLD

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
      requires_filing: total_comp >= FILING_THRESHOLD,
      w9_on_file: contractor.w9_on_file?,
      compliance_issues: compliance_issues
    }
  end
end
