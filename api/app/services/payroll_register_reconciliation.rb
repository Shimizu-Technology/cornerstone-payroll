# frozen_string_literal: true

# Report-only checks against saved paycheck amounts. Total deductions already
# includes employee taxes and tips paid out; employer contributions are separate.
class PayrollRegisterReconciliation
  def self.traditional_retirement(worker)
    worker.fetch(:traditional_retirement_total, worker[:retirement_payment]).to_d
  end

  def self.roth_retirement(worker)
    worker.fetch(:roth_retirement_total, worker[:roth_retirement_payment]).to_d
  end

  def self.non_taxable_additions(worker)
    return worker[:non_taxable_additions_total].to_d if worker.key?(:non_taxable_additions_total)

    %i[non_taxable_pay payroll_adjustment_non_taxable_additions_total payroll_field_non_taxable_additions_total]
      .sum(0.to_d) { |key| worker[key].to_d }
  end

  def self.review_rows(report)
    (Array(report[:employees]) + Array(report[:contractors])).filter_map do |worker|
      expected = (worker[:gross_pay].to_d + non_taxable_additions(worker) - worker[:total_deductions].to_d).round(2)
      difference = expected - worker[:net_pay].to_d.round(2)
      next if difference.zero?

      {
        severity: "Review",
        employee: worker[:employee_name],
        issue: "Payroll row does not reconcile",
        detail: format("Gross + non-taxable additions - deductions (including employee taxes) = $%.2f; saved net $%.2f; difference $%.2f. Employer contributions do not reduce net.", expected, worker[:net_pay].to_d, difference)
      }
    end
  end
end
