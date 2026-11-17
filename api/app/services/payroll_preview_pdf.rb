# frozen_string_literal: true

require "combine_pdf"

# Pure rendering: numbering, print events, review revisions and payroll state
# belong to their existing workflows. The caller records the download audit.
class PayrollPreviewPdf
  def self.generate(pay_period:, company:, part: nil)
    raise ArgumentError, "Choose checks, stubs or all_stubs" unless part.in?([ nil, "checks", "stubs", "all_stubs" ])

    items = pay_period.payroll_items.reportable.not_voided
      .includes(:payroll_item_earnings, :payroll_item_field_entries,
        { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company })
      .to_a.sort_by { |item| [ item.employee.last_name.to_s.downcase, item.employee.first_name.to_s.downcase, item.id ] }
    pdf = CombinePDF.new
    unless part.in?(%w[stubs all_stubs])
      checks = items.select { |item| item.effective_payment_delivery_method == "paper_check" && item.net_pay.to_d.positive? }
      if checks.any?
        data = if company.first_hawaiian_4up_checks?
          FirstHawaiianFourUpCheckGenerator.new(company: company, payroll_items: checks, preview: true).generate
        else
          CheckGenerator.generate_preview_batch(checks, company: company)
        end
        pdf << CombinePDF.parse(data)
      end
    end
    unless part == "checks"
      statements = items.select do |item|
        part == "all_stubs" ? EarningsStatementEligibility.printable?(item) : EarningsStatementEligibility.separate_statement?(item)
      end
      statements.each do |item|
        pdf << CombinePDF.parse(PayStubGenerator.new(item, preview: true).generate)
      end
    end
    raise ArgumentError, "No #{part || 'checks or pay stubs'} are available for this preview" if pdf.pages.empty?

    pdf.to_pdf
  end
end
