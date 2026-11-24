# frozen_string_literal: true

FactoryBot.define do
  factory :historical_paycheck do
    transient do
      period_type { "regular" }
      batch_status { "locked" }
    end

    employee
    company { employee.company }
    historical_import_batch do
      association(:historical_import_batch, company: company, status: batch_status)
    end
    historical_pay_period do
      HistoricalPayPeriod.create!(
        company: company, historical_import_batch: historical_import_batch, external_key: "period-#{external_key}",
        source_label: "QuickBooks test period", period_type: period_type,
        start_date: period_start, end_date: period_end, pay_date: pay_date
      )
    end
    historical_worker do
      association(:historical_worker, company: company, historical_import_batch: historical_import_batch,
        employee: employee, mapping_status: "exact_match")
    end
    sequence(:external_key) { |number| "historical-paycheck-#{number}" }
    sequence(:source_row_number)
    source_employee_name { employee.full_name }
    source_status { "Paid" }
    reconciliation_status { "matched" }
    pay_date { Date.new(2026, 1, 20) }
    period_start { Date.new(2026, 1, 1) }
    period_end { Date.new(2026, 1, 14) }
    hours_total { 40 }
    gross_pay { 1_000 }
    adjusted_gross { 1_000 }
    net_pay { 900 }
  end
end
