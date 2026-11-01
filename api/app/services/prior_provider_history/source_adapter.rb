# frozen_string_literal: true

module PriorProviderHistory
  # A prefill, never a recalculation or a claim that these were paid amounts.
  class SourceAdapter
    VERSION = "prior-provider-existing-roster-v1"
    MAX_RUNS = 60
    MAX_PAYCHECKS = 2_000

    def self.candidate(period)
      rows = period.payroll_items.includes(:employee, :payroll_item_deductions).order(:employee_id).map do |item|
        taxes = item.withholding_tax.to_d + item.additional_withholding.to_d + item.social_security_tax.to_d + item.medicare_tax.to_d
        pretax = item.retirement_payment.to_d + item.payroll_item_deductions.select(&:pre_tax?).sum(0.to_d, &:amount) + item.pre_tax_payroll_adjustments_total.to_d
        aftertax = item.total_deductions.to_d - taxes - pretax
        row = Amounts::FIELDS.index_with { "0.0" }
        %w[gross_pay net_pay social_security_tax medicare_tax employer_social_security_tax employer_medicare_tax non_taxable_pay reported_tips tips_paid_out].each do |field|
          row[field] = item.public_send(field).to_d.round(2).to_s("F")
        end
        row["gross_pay"] = (item.gross_pay.to_d + item.non_taxable_pay.to_d).round(2).to_s("F")
        %w[fit_taxable_wages social_security_taxable_wages social_security_taxable_tips medicare_taxable_wages additional_medicare_taxable_wages].each do |field|
          row[field] = item.public_send(field)&.to_d&.round(2)&.to_s("F") || ""
        end
        row.merge!(
          "employee_id" => item.employee_id, "source_employee_name" => item.employee.full_name,
          "federal_income_tax" => (item.withholding_tax.to_d + item.additional_withholding.to_d).to_s("F"),
          "pretax_deductions" => pretax.to_s("F"), "after_tax_deductions" => aftertax.to_s("F"),
          "retirement" => item.retirement_payment.to_d.to_s("F"), "roth_retirement" => item.roth_retirement_payment.to_d.to_s("F"),
          "insurance" => item.insurance_payment.to_d.to_s("F"), "loans" => item.loan_payment.to_d.to_s("F"),
          "employer_contributions" => employer_contributions(item)
        )
        row.merge(
          "earnings_breakdown" => component("Earnings (verify source classification)", row["gross_pay"]),
          "pretax_deduction_breakdown" => component("Pre-tax deductions", pretax),
          "after_tax_deduction_breakdown" => component("Post-tax deductions", aftertax),
          "employer_contribution_breakdown" => component("Employer contributions", row["employer_contributions"])
        )
      end
      {
        "key" => "run-#{period.id}", "run_id" => period.id, "start_date" => period.start_date.iso8601,
        "end_date" => period.end_date.iso8601, "pay_date" => period.pay_date.iso8601,
        "paychecks" => rows, "calculated_totals" => Amounts.totals(rows),
        "source_digest" => digest(period), "source_reference" => "", "register_totals" => {}
      }
    end

    # Runs calculated before employer-component provenance was recorded can be
    # ambiguous. Leave the amount blank so the operator enters it from the paid
    # register; selection and conversion never depend on a recalculation.
    def self.employer_contributions(item)
      PayrollEmployerContributions.total(item).to_s("F")
    rescue PayrollComponentMirrors::AmbiguousHistoryError
      ""
    end

    def self.component(label, amount)
      amount.to_d.zero? ? [] : [ { "label" => label, "amount" => amount.to_d.to_s("F") } ]
    end

    # Fingerprint all retained source data, including child component inputs.
    # Child writes acquire the same parent lock as conversion.
    def self.digest(period)
      rows = period.payroll_items.order(:id).map do |item|
        [ item.attributes, item.payroll_item_deductions.order(:id).map(&:attributes), item.payroll_item_field_entries.order(:id).map(&:attributes) ]
      end
      Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize([ period.attributes, rows ])))
    end
  end
end
