# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Earned payroll and retired checks" do
  include ActiveSupport::Testing::TimeHelpers
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company, pay_rate: 15, pay_frequency: "biweekly", allowances: 0) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let!(:item) do
    row = period.payroll_items.build(employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 60)
    PayrollCalculator.for(employee, row).calculate
    row.save!
    company.assign_check_numbers!([ row ])
    employee.ytd_totals_for(2024).add_payroll_item!(row)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(row)
    PayrollLiabilityPostingService.post!(pay_period: period, actor: actor)
    row.reload
  end

  def financial_snapshot
    {
      w2: W2GuAggregator.new(company, 2024, include_historical: false).generate.fetch(:employees),
      form941: Form941GuAggregator.new(company, 2024, 1, include_historical: false).generate.slice(:lines, :monthly_breakdown, :tax_detail, :withholding_reconciliation),
      form500: Form500Generator.default_fields(company: company, pay_period: period),
      employee_ytd: employee.ytd_totals_for(2024).reload.attributes.except("updated_at"),
      company_ytd: CompanyYtdTotal.find_by!(company: company, year: 2024).attributes.except("updated_at"),
      computed_ytd: employee.calculate_ytd_gross(2024),
      cap_context: employee.ytd_totals_before(year: 2024, pay_date: Date.new(2024, 12, 31), pay_period_id: period.id + 1),
      liability: period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount"),
      tax: PayrollTaxSyncPayloadBuilder.new(period.reload).build.slice(:line_items, :totals)
    }
  end

  it "retains the committed $900 in reports, computed YTD, caps, cached YTD, tax payload and liabilities" do
    expect(item.gross_pay).to eq(900)
    before = financial_snapshot
    item.void!(user: actor, reason: "Retire damaged paper check only")
    expect(item.reload).to be_voided
    expect(financial_snapshot).to eq(before)
    expect(item.check_events.voids.last.details).to include("payroll_obligation_retained" => true)
  end

  it "preserves earned payroll and instrument audit when clearing evidence blocks retirement or reversal" do
    CheckReconciliationEvent.create!(company: company, pay_period: period, payroll_item: item, recorded_by: actor,
      event_type: "cleared", check_number: item.check_number, amount: item.net_pay,
      effective_on: period.pay_date, evidence_type: "bank_statement", idempotency_key: "cleared-synthetic-check")
    before = financial_snapshot
    expect { item.void!(user: actor, reason: "Cannot retire a cleared check") }.to raise_error(ArgumentError, /clearing evidence/)
    expect { ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Cannot reverse a cleared payment") }.to raise_error(ArgumentError, /clearing evidence/)
    expect(item.reload).not_to be_voided
    expect(financial_snapshot).to eq(before)
  end

  it "detects legacy instrument voids without repairing data and excludes new retirement and financial reversals" do
    item.update!(voided: true, voided_at: Time.current, void_reason: "Legacy damaged check")
    item.check_events.create!(user: actor, event_type: "voided", check_number: item.check_number, reason: item.void_reason)
    expect(LegacyCheckVoidDetection.items).to include(item)
    snapshot = item.reload.attributes
    expect(LegacyCheckVoidDetection.items.pluck(:id)).to eq([ item.id ])
    expect(item.reload.attributes).to eq(snapshot)
    ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Explicit accounting reversal")
    expect(LegacyCheckVoidDetection.items).not_to include(item)
  end

  it "uses a distinct tax revision for separate reversals within the same second" do
    other = create(:employee, company: company)
    other_item = create(:payroll_item, pay_period: period, employee: other, gross_pay: 100, net_pay: 100)
    other.ytd_totals_for(2024).add_payroll_item!(other_item)
    CompanyYtdTotal.find_by!(company: company, year: 2024).add_payroll_item!(other_item)
    allow(PayrollTaxSyncService).to receive(:configured?).and_return(true)
    freeze_time do
      ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Reverse first incorrect wages")
      first_key = period.reload.tax_sync_idempotency_key
      ReversePaycheckService.call(payroll_item: other_item, actor: actor, reason: "Reverse second incorrect wages")
      expect(period.reload.tax_sync_idempotency_key).not_to eq(first_key)
      expect(PayrollTaxSyncPayloadBuilder.new(period).build[:totals][:gross_pay]).to eq(0)
    end
  end

  %w[delivered cleared direct_deposit].each do |payment_state|
    it "reverses the selected paycheck while another employee's payment is #{payment_state}" do
      other = create(:employee, company: company)
      other_item = create(:payroll_item, :with_check, pay_period: period, employee: other, check_number: "9001")
      other.ytd_totals_for(2024).add_payroll_item!(other_item)
      CompanyYtdTotal.find_by!(company: company, year: 2024).add_payroll_item!(other_item)
      case payment_state
      when "delivered"
        other_item.check_events.create!(user: actor, event_type: "delivered", check_number: other_item.check_number)
      when "cleared"
        CheckReconciliationEvent.create!(company: company, pay_period: period, payroll_item: other_item, recorded_by: actor,
          event_type: "cleared", check_number: other_item.check_number, amount: other_item.net_pay,
          effective_on: period.pay_date, evidence_type: "bank_statement", idempotency_key: "other-cleared-check")
      else
        other_item.update!(payment_delivery_method: "direct_deposit", check_number: nil)
      end
      other_before = other_item.reload.attributes

      ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Reverse selected incorrect paycheck only")

      expect(item.reload).not_to be_payroll_included
      expect(other_item.reload.attributes).to eq(other_before)
      expect(other.ytd_totals_for(2024).reload.gross_pay).to eq(other_item.gross_pay)
      expect(CompanyYtdTotal.find_by!(company: company, year: 2024).gross_pay).to eq(other_item.gross_pay)
    end
  end

  it "still blocks the selected paycheck's own positive direct deposit" do
    item.update!(payment_delivery_method: "direct_deposit", check_number: nil)
    before = financial_snapshot
    expect { ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Cannot reverse an external deposit") }
      .to raise_error(ArgumentError, /direct-deposit reversal/)
    expect(financial_snapshot).to eq(before)
  end

  it "records a financial void rather than retained-obligation cancellation when reversing an active check" do
    item.check_events.create!(user: actor, event_type: "printed", check_number: item.check_number)
    ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Reverse an incorrect unpaid paycheck")
    event = item.check_events.voids.last
    expect(event.details).to include("payroll_obligation_retained" => false, "original_check_cancelled" => false)
    expect(event.payment_cancellation?).to be(false)
  end

  it "nets restated liability components once and preserves every reversed entry id" do
    old_date = period.pay_date
    period.update!(pay_date: old_date + 14)
    PayrollLiabilityPostingService.restate_for_pay_date!(pay_period: period, actor: actor,
      old_pay_date: old_date, new_pay_date: period.pay_date)
    entries = PayrollLiabilityEntry.joins(:payroll_liability_posting)
      .where(payroll_liability_postings: { pay_period_id: period.id }, payroll_item_id: item.id).to_a

    ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Reverse after pay date restatement")

    reversal = period.payroll_liability_postings.find_by!(posting_type: "paycheck_reversal")
    expect(reversal.entries.pluck(:component_key).uniq.size).to eq(reversal.entries.count)
    entries.group_by(&:component_key).each do |key, components|
      offset = reversal.entries.find_by!(component_key: key)
      expect(offset.amount).to eq(-components.sum(&:amount))
      expect(offset.metadata.fetch("reverses_entry_ids")).to match_array(components.map(&:id))
    end
    expect(period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")).to eq(0)
  end

  it "omits a liability component whose prior journal entries already net to zero" do
    source = period.payroll_liability_postings.first
    entry = source.entries.first
    prior_offset = PayrollLiabilityPosting.create!(company: company, pay_period: period, posting_type: "reversal",
      source_posting: source, liability_date: period.pay_date, posted_at: Time.current, posted_by: actor,
      reason: "Previously offset component", idempotency_key: "prior-component-offset")
    prior_offset.entries.create!(entry.attributes.except("id", "created_at", "updated_at", "payroll_liability_posting_id")
      .merge("amount" => -entry.amount))

    ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Reverse remaining financial components")

    reversal = period.payroll_liability_postings.find_by!(posting_type: "paycheck_reversal")
    expect(reversal.entries.where(component_key: entry.component_key)).to be_empty
    expect(period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")).to eq(0)
  end

  %i[payroll_reversed_at payroll_reversed_by_id payroll_reversal_reason].combination(1).to_a
    .concat(%i[payroll_reversed_at payroll_reversed_by_id payroll_reversal_reason].combination(2).to_a).each do |fields|
    it "rejects partial reversal audit fields #{fields.join(', ')} at the database boundary" do
      values = { payroll_reversed_at: Time.current, payroll_reversed_by_id: actor.id, payroll_reversal_reason: "Reviewed reversal" }
      expect { item.update_columns(values.slice(*fields)) }
        .to raise_error(ActiveRecord::StatementInvalid, /check_payroll_item_reversal_fields/)
    end
  end

  it "refreshes later saved statement YTD without recalculating its earned amounts" do
    later_period = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
    later = later_period.payroll_items.build(employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 60)
    PayrollCalculator.for(employee, later).calculate
    later.save!
    expect(later.ytd_gross).to eq(1800)
    money = later.attributes.slice("gross_pay", "net_pay", "withholding_tax", "social_security_tax", "medicare_tax")
    ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Reverse earlier erroneous wages")
    expect(later.reload.attributes.slice(*money.keys)).to eq(money)
    expect(later).to have_attributes(ytd_gross: 900, ytd_net: later.net_pay, ytd_withholding_tax: later.withholding_tax,
      ytd_social_security_tax: later.social_security_tax, ytd_medicare_tax: later.medicare_tax)
  end

  it "reverses one paycheck exactly once, then whole-period void skips its prior financial reversal" do
    other = create(:employee, company: company)
    other_item = create(:payroll_item, pay_period: period, employee: other, gross_pay: 100, net_pay: 100)
    other.ytd_totals_for(2024).add_payroll_item!(other_item)
    CompanyYtdTotal.find_by!(company: company, year: 2024).add_payroll_item!(other_item)
    item.void!(user: actor, reason: "Retire damaged paper check only")
    ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Reverse erroneous earned wages")
    expect(item.reload).not_to be_payroll_included
    expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(0)
    expect(employee.calculate_ytd_gross(2024)).to eq(0)
    expect(CompanyYtdTotal.find_by!(company: company, year: 2024).gross_pay).to eq(100)
    expect(period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")).to eq(0)
    expect(W2GuAggregator.new(company, 2024, include_historical: false).generate.fetch(:employees).map { |r| r[:employee_id] }).not_to include(employee.id)
    expect(PayrollTaxSyncPayloadBuilder.new(period).build[:line_items].map { |r| r[:payroll_item_id] }).not_to include(item.id)
    expect { ReversePaycheckService.call(payroll_item: item, actor: actor, reason: "Duplicate reversal request") }.to raise_error(ArgumentError, /already been reversed/)
    PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Reverse remaining payroll wages")
    expect(CompanyYtdTotal.find_by!(company: company, year: 2024).gross_pay).to eq(0)
    expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(0)
    expect(period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")).to eq(0)
    correction = PayPeriodCorrectionService.create_correction_run!(source_pay_period: period.reload, actor: actor, reason: "Correct remaining payroll only")
    expect(correction.payroll_items.pluck(:employee_id)).to eq([ other.id ])
  end
end
