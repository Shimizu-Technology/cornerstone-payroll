# frozen_string_literal: true

require_relative "parity_helper"

# Staff registers read each paycheck's statement YTD in a batch. It must be
# the same figure the statement prints, paycheck by paycheck.
RSpec.describe StatementYtdFigures, type: :request do
  include Parity::ParityContext

  def statement_figures(item)
    sources = PayrollStatementYtdSources.new(item)
    totals = sources.totals
    {
      gross: PayrollEarningsYtdBreakdown.new(item, sources: sources).pay_ytd_total(totals[:gross]),
      net: totals[:net], withholding_tax: totals[:withholding_tax], social_security_tax: totals[:social_security_tax],
      medicare_tax: totals[:medicare_tax], additional_withholding: totals[:additional_withholding]
    }
  end

  it "matches PayrollStatementYtdSources for every fixture paycheck, primed per pay run" do
    items = fixture.items.values.map(&:reload)
    figures = described_class.new.prime(items)

    items.each do |item|
      expect(figures.call(item).to_h).to eq(statement_figures(item)), "statement YTD differs for payroll item #{item.id}"
    end
  end

  context "with an opening balance and a native paycheck recorded distinct inside it" do
    let(:fixture_scenarios) { [ :prior_provider_ytd ] }

    it "counts the recorded paycheck exactly as the statement does" do
      employee = fixture.employees.fetch(:prior_provider_ytd)
      period = PayPeriod.new(company: fixture.company, status: "committed", start_date: Date.new(2025, 12, 25),
        end_date: Date.new(2026, 1, 7), pay_date: Date.new(2026, 1, 9), committed_at: Time.zone.parse("2026-01-08 09:00"))
      period.save!(validate: false)
      inside = period.payroll_items.build(company: fixture.company, employee: employee, employment_type: "hourly",
        pay_rate: BigDecimal("22.00"), hours_worked: BigDecimal("40.00"), payment_delivery_method: "direct_deposit")
      PayrollCalculator.for(employee, inside).calculate
      inside.save!
      later = fixture.items.fetch(:prior_provider_ytd_p2).reload

      expect(described_class.new.call(later).to_h).to eq(statement_figures(later))
      PayrollBridgeOverlapDispositionService.record_evident!(company_id: fixture.company.id, year: 2026, actor: fixture.staff_user)
      expect(described_class.new.call(later).to_h).to eq(statement_figures(later.reload))
      expect(described_class.new.call(later).gross).to eq(
        (fixture.qb_records.fetch(:ytd_balance).statement_gross_pay + inside.gross_pay.to_d + later.gross_pay.to_d).round(2)
      )
    end
  end

  it "reads a whole pay run in a fixed number of queries" do
    items = fixture.period2.payroll_items.includes(:pay_period, :company).to_a
    expect(items.size).to be > 5
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      figures = described_class.new.prime(items)
      items.each { |item| figures.call(item) }
    end
    expect(queries).to be <= 5
  end
end
