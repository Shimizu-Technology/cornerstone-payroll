# frozen_string_literal: true

module PriorPeriodEarningsFixture
  def captured_prior_period_earnings(item)
    item.pay_period.update!(start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
    category = "Ground Instruction and Administrative Training Duties"
    current = "#{category} · AIRE current period · $10.00/hr"
    prior = "#{category} · AIRE carryover from Dec 31–Sep 15, 2026 · $10.00/hr"
    source_line = lambda do |id, date, kind, regular, overtime|
      { "source_time_entry_id" => id, "line_key" => id, "source_time_entry_version" => 1,
        "source_kind" => kind, "original_work_date" => date, "regular_hours" => regular,
        "overtime_hours" => overtime, "total_hours" => regular + overtime }
    end
    rates = [
      { "label" => current, "rate" => 10, "regular_hours" => 8, "overtime_hours" => 0,
        "source_bucket_key" => "current", "source_lines" => [ source_line.call("1", item.pay_period.start_date.iso8601, "current", 8, 0) ] },
      { "label" => prior, "rate" => 10, "regular_hours" => 4.25, "overtime_hours" => 2,
        "source_bucket_key" => "prior", "source_lines" => [ source_line.call("2", "2025-12-31", "carryover", 2, 1), source_line.call("3", "2026-09-15", "carryover", 2.25, 1) ] }
    ]
    item.update!(wage_rate_hours: rates, hours_worked: 12.25, overtime_hours: 2,
      gross_pay: 152.50, net_pay: 152.50, ytd_gross: 152.50, ytd_net: 152.50, bonus: 0, reported_tips: 0, custom_earnings: [], custom_deductions: [],
      withholding_tax: 0, social_security_tax: 0, medicare_tax: 0, total_deductions: 0)
    item.payroll_item_earnings.delete_all
    item.payroll_item_earnings.create!(category: "regular", label: current, hours: 8, rate: 10, amount: 80)
    item.payroll_item_earnings.create!(category: "regular", label: prior, hours: 4.25, rate: 10, amount: 42.50)
    item.payroll_item_earnings.create!(category: "overtime", label: "#{prior} OT", hours: 2, rate: 15, amount: 30)
    item.reload
  end
end
