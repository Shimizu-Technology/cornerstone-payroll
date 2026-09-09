# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFilingResponsibilityGate do
  let(:company) { create(:company) }
  let(:reviewer) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let(:tax_year) { 2026 }
  let(:quarter) { 2 }

  def create_historical_period(period_type: "regular", status: "locked", pay_date: Date.new(2026, 5, 8), locked_at: 1.day.ago)
    batch = create(
      :historical_import_batch,
      company: company,
      status: status,
      locked_at: status == "locked" ? locked_at : nil,
      locked_by: status == "locked" ? reviewer : nil
    )
    HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "period-#{batch.id}",
      source_label: batch.source_label,
      period_type: period_type,
      start_date: pay_date - 13.days,
      end_date: pay_date - 5.days,
      pay_date: pay_date,
      paycheck_count: 1
    )
  end

  def gate(filing_type: "form_941")
    described_class.new(
      company: company,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: filing_type
    ).payload
  end

  it "does not require a responsibility record for native-only payroll" do
    create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 5, 8))

    result = gate

    expect(result[:status]).to eq("responsibility_not_required")
    expect(result[:blockers]).to be_empty
    expect(result.dig(:capabilities, :can_mark_filing_ready)).to be(true)
  end

  it "requires a filing-specific decision when locked imported payroll is in-period" do
    create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 5, 8))
    create_historical_period

    result = gate

    expect(result[:source_coverage]).to include(
      native_pay_period_count: 1,
      historical_pay_period_count: 1,
      mixed_sources: true
    )
    expect(result[:blockers].sole[:code]).to eq("PAYROLL_FILING_RESPONSIBILITY_REQUIRED")
    expect(result.dig(:capabilities, :can_review_draft)).to be(true)
    expect(result.dig(:capabilities, :can_export_draft)).to be(true)
    expect(result.dig(:capabilities, :can_export_filing_ready)).to be(false)
  end

  it "ignores opening summaries and imports that are not locked" do
    create_historical_period(period_type: "opening_summary")
    create_historical_period(status: "applied", pay_date: Date.new(2026, 5, 22))

    result = gate

    expect(result.dig(:source_coverage, :historical_pay_period_count)).to eq(0)
    expect(result[:blockers]).to be_empty
  end

  it "keeps Cornerstone filing blocked when in-period imported wages are excluded" do
    create_historical_period
    create(
      :payroll_filing_responsibility,
      company: company,
      reviewed_by: reviewer,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: "form_941",
      responsible_party: "cornerstone",
      imported_payroll_inclusion: "excluded"
    )

    result = gate

    expect(result[:status]).to eq("historical_payroll_excluded")
    expect(result[:blockers].sole[:code]).to eq("HISTORICAL_PAYROLL_EXCLUSION_UNSAFE")
  end

  it "keeps Cornerstone filing blocked when an external provider is responsible" do
    create_historical_period
    create(
      :payroll_filing_responsibility,
      :external_provider,
      company: company,
      reviewed_by: reviewer,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: "form_941"
    )

    result = gate

    expect(result[:status]).to eq("external_provider_responsible")
    expect(result[:blockers].sole[:code]).to eq("EXTERNAL_PROVIDER_RESPONSIBLE")
  end

  it "allows filing readiness after Cornerstone accepts the imported payroll" do
    create_historical_period(locked_at: 2.days.ago)
    create(
      :payroll_filing_responsibility,
      company: company,
      reviewed_by: reviewer,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: "form_941",
      responsible_party: "cornerstone",
      imported_payroll_inclusion: "included",
      reviewed_at: 1.day.ago
    )

    result = gate

    expect(result[:status]).to eq("cornerstone_responsible")
    expect(result[:blockers]).to be_empty
    expect(result.dig(:capabilities, :can_export_filing_ready)).to be(true)
  end

  it "requires re-review when more historical payroll is locked after the decision" do
    create_historical_period(locked_at: Time.current)
    create(
      :payroll_filing_responsibility,
      company: company,
      reviewed_by: reviewer,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: "form_941",
      reviewed_at: 1.day.ago
    )

    result = gate

    expect(result[:status]).to eq("review_stale")
    expect(result[:blockers].sole[:code]).to eq("PAYROLL_FILING_RESPONSIBILITY_STALE")
  end

  it "groups quarterly filing owners without inferring one form from another" do
    create_historical_period(locked_at: 2.days.ago)
    create(
      :payroll_filing_responsibility,
      company: company,
      reviewed_by: reviewer,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: "form_941",
      reviewed_at: 1.day.ago
    )

    result = described_class.quarterly(company: company, tax_year: tax_year, quarter: quarter)

    expect(result.dig(:filings, "form_941", :status)).to eq("cornerstone_responsible")
    expect(result.dig(:filings, "guam_withholding", :status)).to eq("responsibility_required")
    expect(result.dig(:filings, "swica", :status)).to eq("responsibility_required")
  end

  it "uses an independent annual W-2GU decision" do
    create_historical_period(pay_date: Date.new(2026, 5, 8), locked_at: 2.days.ago)
    create(
      :payroll_filing_responsibility,
      company: company,
      reviewed_by: reviewer,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: "form_941",
      reviewed_at: 1.day.ago
    )

    result = described_class.annual(company: company, tax_year: tax_year)

    expect(result.dig(:filings, "w2_gu", :status)).to eq("responsibility_required")
    expect(result.dig(:capabilities, :all_filing_ready_exports_allowed)).to be(false)
  end
end
