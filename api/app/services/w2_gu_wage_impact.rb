# frozen_string_literal: true

# Comparison against the pre-milestone year-end rules, using the same eligible
# sources and annual employee caps as W2GuAggregator. No paycheck writes.
class W2GuWageImpact < W2GuAggregator
  def generate
    current = super.fetch(:totals)
    old = employees.map do |employee|
      items = live_items.where(employee_id: employee.id).to_a
      historical = historical_balances_by_employee.fetch(employee.id, [])
      retirement = aggregated_retirement.fetch(employee.id, {})
      old_box1 = items.sum(0.to_d, &:gross_pay) - retirement[:retirement].to_d + historical.sum(0.to_d) do |balance|
        balance.source_breakdown.to_h["prior_provider_verified"] ? balance.fit_taxable_wages.to_d : balance.gross_pay.to_d - balance.retirement.to_d
      end
      old_ss = items.sum(0.to_d) { |item| item.social_security_taxable_wages || [ item.gross_pay.to_d - item.reported_tips.to_d, 0.to_d ].max } +
        historical_sum(historical, :social_security_taxable_wages)
      old_medicare = items.sum(0.to_d) { |item| item.medicare_taxable_wages || item.gross_pay.to_d } +
        historical_sum(historical, :medicare_taxable_wages)
      [ old_box1.round(2), [ old_ss, ss_wage_base ].min.round(2), old_medicare.round(2) ]
    end
    {
      box1: comparison(old.sum(0.to_d) { |values| values[0] }, current.fetch(:box1_wages_tips_other_comp)),
      box3: comparison(old.sum(0.to_d) { |values| values[1] }, current.fetch(:box3_social_security_wages)),
      box5: comparison(old.sum(0.to_d) { |values| values[2] }, current.fetch(:box5_medicare_wages_tips))
    }
  end

  private

  def comparison(old, current)
    [ old, current.to_d, (current.to_d - old).round(2) ]
  end
end
