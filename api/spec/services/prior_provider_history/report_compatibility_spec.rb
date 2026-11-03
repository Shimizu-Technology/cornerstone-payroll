# frozen_string_literal: true

require "spec_helper"
require "active_support/all"
require_relative "../../../app/services/unified_payroll_reporting"
require_relative "../../../app/services/historical_payroll_filing_source"
require_relative "../../../app/services/form_941_gu_aggregator"
require_relative "../../../app/services/w2_gu_aggregator"
require_relative "../../../app/services/quarterly_compliance_packet_builder"

RSpec.describe "Prior-provider report compatibility" do
  let(:range) { Date.new(2026, 7, 1)..Date.new(2026, 9, 30) }

  [ [], [ "quickbooks_online" ], [ "prior_provider" ] ].each do |systems|
    it "limits new source metadata to prior-provider input for #{systems.inspect}" do
      source = double(metadata: {}, source_systems: systems, opening_summary_count: 0)
      quarterly = Form941GuAggregator.allocate
      allow(quarterly).to receive_messages(include_historical: true, historical_source: source,
        year: 2026, quarter_start_date: range.begin, quarter_end_date: range.end, committed_pay_periods: [])
      annual = W2GuAggregator.allocate
      allow(annual).to receive_messages(include_historical: true, historical_source: source,
        year_range: range, aggregated_items: {}, historical_balances: [])
      summaries = [ quarterly.send(:source_summary, []), annual.send(:source_summary) ]
      summaries.each do |summary|
        expect(summary.key?(:historical_source_systems)).to eq(systems.include?("prior_provider"))
        expect(summary[:mode]).to eq(systems.include?("prior_provider") ? "locked_historical_plus_committed_cornerstone" : "locked_quickbooks_plus_committed_cornerstone")
      end
      expect(annual.send(:historical_caveats).first).to start_with(systems.include?("prior_provider") ? "Historical values" : "QuickBooks values")
      packet = QuarterlyCompliancePacketBuilder.new(nil, 2026, 3)
      allow(packet).to receive(:historical_payroll_source).and_return(source)
      expected_label = systems.include?("prior_provider") ? "Locked historical wages" : "Locked QuickBooks wages"
      expect(packet.send(:source_rules)[:imported_payroll]).to start_with(expected_label)
    end
  end

  it "preserves the native YTD source-summary contract without an empty provider section" do
    reporting = UnifiedPayrollReporting.new(company_id: 1, period: nil)
    allow(reporting).to receive(:bridge_summary).and_return({ applied: false })
    summary = reporting.source_summary(native_items: [], historical_paychecks: [])
    expect(summary.keys).to eq(%i[mode source_statement cornerstone quickbooks adjustments source_overlap historical_ytd_bridge])
    expect(summary[:mode]).to eq("committed_cornerstone_only")
    expect(summary[:source_statement]).to eq(UnifiedPayrollReporting::SOURCE_STATEMENT)
  end
  it "keeps the exact legacy QuickBooks summary and splits provider counts and statement only when provider rows exist" do
    reporting = UnifiedPayrollReporting.new(company_id: 1, period: nil)
    allow(reporting).to receive(:bridge_summary).and_return({ applied: false })
    row = lambda do |source, id|
      double(historical_import_batch: double(source_system: source), historical_pay_period: double(period_type: "regular"),
        historical_pay_period_id: id, employee_id: id, pay_date: Date.new(2026, 10, 28), gross_pay: 100.to_d, net_pay: 80.to_d)
    end
    qb = row.call("quickbooks_online", 1)
    prior = row.call("prior_provider", 2)
    counts = { payroll_count: 1, paycheck_count: 1, record_count: 1, opening_summary_count: 0,
      excluded_unlinked_paycheck_count: 0, excluded_unlinked_gross_pay: 0, excluded_unlinked_net_pay: 0 }
    legacy = reporting.source_summary(native_items: [], historical_paychecks: [ qb ])
    expect(legacy).to eq(mode: "locked_quickbooks_plus_committed_cornerstone", source_statement: UnifiedPayrollReporting::SOURCE_STATEMENT,
      cornerstone: { payroll_count: 0, paycheck_count: 0 }, quickbooks: counts,
      adjustments: { count: 0, gross_pay_delta: 0, net_pay_delta: 0 }, source_overlap: { employee_pay_date_count: 0 }, historical_ytd_bridge: { applied: false })
    mixed = reporting.source_summary(native_items: [], historical_paychecks: [ qb, prior ])
    expect(mixed[:quickbooks]).to eq(counts)
    expect(mixed[:prior_provider]).to eq(counts)
    expect(mixed[:source_statement]).to include("Prior-provider payments were already paid")
    expect(mixed[:source_statement]).not_to include("QuickBooks source values")
  end

  it "derives the Form 941 mode from every source that feeds the quarter, including earlier-quarter provider wages" do
    quarterly = lambda do |earlier_systems|
      source = double(metadata: {}, opening_summary_count: 0)
      # Only earlier quarters hold history; the requested Q3 itself has none.
      allow(source).to receive(:source_systems) { |range:| range.begin < range.begin.change(month: 7) ? earlier_systems : [] }
      aggregator = Form941GuAggregator.allocate
      allow(aggregator).to receive_messages(include_historical: true, historical_source: source,
        year: 2026, quarter_start_date: range.begin, quarter_end_date: range.end, committed_pay_periods: [])
      aggregator.send(:source_summary, [])
    end
    provider = quarterly.call([ "prior_provider" ])
    expect(provider[:mode]).to eq("locked_historical_plus_committed_cornerstone")
    expect(provider[:historical_source_systems]).to eq([ "prior_provider" ])
    # Earlier-quarter QuickBooks history keeps the exact legacy summary.
    [ [], [ "quickbooks_online" ] ].each do |systems|
      legacy = quarterly.call(systems)
      expect(legacy.keys).to eq(%i[mode cornerstone quickbooks])
      expect(legacy[:mode]).to eq("locked_quickbooks_plus_committed_cornerstone")
    end
  end

  it "keeps quarterly taxability amounts attributed to their own source and single-source rows unchanged" do
    record = lambda do |source, gross, tips, non_taxable|
      double(source_system: source, gross_pay: gross.to_d, reported_tips: tips.to_d, non_taxable_pay: non_taxable.to_d)
    end
    rows_for = lambda do |records|
      packet = QuarterlyCompliancePacketBuilder.new(nil, 2026, 3)
      allow(packet).to receive(:historical_records).and_return(records)
      packet.send(:historical_component_taxability).map { |row| row.slice(:category, :label, :amount, :source, :social_security_wages, :non_taxable) }
    end
    quickbooks = [ record.call("quickbooks_online", 1_000, 100, 50), record.call("quickbooks_online", 500, 0, 0) ]
    provider = [ record.call("prior_provider", 2_000, 0, 25) ]
    expect(rows_for.call(quickbooks)).to eq([
      { category: "regular", label: "Imported taxable wages", amount: 1_350.0, source: "quickbooks", social_security_wages: true, non_taxable: false },
      { category: "tips", label: "Imported reported tips", amount: 100.0, source: "quickbooks", social_security_wages: false, non_taxable: false },
      { category: "non_taxable", label: "Imported non-taxable pay", amount: 50.0, source: "quickbooks", social_security_wages: false, non_taxable: true }
    ])
    expect(rows_for.call(provider)).to eq([
      { category: "regular", label: "Imported taxable wages", amount: 1_975.0, source: "prior_provider", social_security_wages: true, non_taxable: false },
      { category: "non_taxable", label: "Imported non-taxable pay", amount: 25.0, source: "prior_provider", social_security_wages: false, non_taxable: true }
    ])
    expect(rows_for.call(quickbooks + provider)).to eq([
      { category: "regular", label: "Imported taxable wages (prior provider)", amount: 1_975.0, source: "prior_provider", social_security_wages: true, non_taxable: false },
      { category: "non_taxable", label: "Imported non-taxable pay (prior provider)", amount: 25.0, source: "prior_provider", social_security_wages: false, non_taxable: true },
      { category: "regular", label: "Imported taxable wages (QuickBooks)", amount: 1_350.0, source: "quickbooks", social_security_wages: true, non_taxable: false },
      { category: "tips", label: "Imported reported tips (QuickBooks)", amount: 100.0, source: "quickbooks", social_security_wages: false, non_taxable: false },
      { category: "non_taxable", label: "Imported non-taxable pay (QuickBooks)", amount: 50.0, source: "quickbooks", social_security_wages: false, non_taxable: true }
    ])
  end

  it "labels historical deduction components with their own source and keeps QuickBooks and adjustment entries unchanged" do
    reporting = UnifiedPayrollReporting.new(company_id: 1, period: nil)
    paycheck = lambda do |source, employee_id|
      double(historical_import_batch: double(source_system: source), employee_id: employee_id,
        pretax_deduction_breakdown: [ { "label" => "401(k) pre-tax retirement", "amount" => "50.00" } ],
        after_tax_deduction_breakdown: [ { "label" => "Loan", "amount" => "10.00" } ])
    end
    adjustment = double(historical_paycheck: double(employee_id: 3),
      pretax_deduction_breakdown: [ { "label" => "401(k) pre-tax retirement", "amount" => "-5.00" } ], after_tax_deduction_breakdown: [])
    entries = reporting.historical_deduction_entries([ paycheck.call("quickbooks_online", 1), paycheck.call("prior_provider", 2) ], [ adjustment ])
    expect(entries).to eq([
      { employee_id: 1, source: "quickbooks", treatment: "pre_tax_deduction", label: "401(k) pre-tax retirement", amount: BigDecimal("50") },
      { employee_id: 1, source: "quickbooks", treatment: "post_tax_deduction", label: "Loan", amount: BigDecimal("10") },
      { employee_id: 2, source: "prior_provider", treatment: "pre_tax_deduction", label: "401(k) pre-tax retirement", amount: BigDecimal("50") },
      { employee_id: 2, source: "prior_provider", treatment: "post_tax_deduction", label: "Loan", amount: BigDecimal("10") },
      { employee_id: 3, source: "historical_adjustment", treatment: "pre_tax_deduction", label: "401(k) pre-tax retirement", amount: BigDecimal("-5") }
    ])
  end
end
