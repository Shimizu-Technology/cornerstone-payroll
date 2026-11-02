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
end
