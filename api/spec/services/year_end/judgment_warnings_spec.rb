# frozen_string_literal: true

require "rails_helper"

RSpec.describe YearEnd::JudgmentWarnings do
  let(:company) { create(:company) }
  let(:reviewer) { create(:user, company: company, organization: company.organization, role: "accountant") }

  def row(id, **flags)
    {
      employee_id: id, employee_name: "Worker #{id}", reported_tips_total: 0.0, box12: [], box14b_tipped_occupation_codes: [],
      source_summary: { cornerstone_payroll_item_count: 3 }, **flags
    }
  end

  def warnings(rows, year: 2026, reconciliation: nil, review_warnings: [])
    described_class.new(company: company, year: year, w2_report: { employees: rows, review_warnings: review_warnings }, reconciliation: reconciliation).call
      .index_by { |warning| warning[:code] }
  end

  it "makes correctable data a blocker that cannot be acknowledged" do
    result = warnings([ row(1, negative_box12_tp: true) ])

    expect(result.fetch("negative_box12_amounts")).to include(kind: "blocker", status: "blocked", acknowledgement: nil)
    expect(result.fetch("negative_box12_amounts")[:employees]).to contain_exactly(a_hash_including(employee_id: 1, name: "Worker 1"))
  end

  it "makes judgment calls need a review, which stays current only while the data is unchanged" do
    rows = [ row(2, missing_committed_tax_bases: true) ]
    warning = warnings(rows).fetch("legacy_tax_bases")
    expect(warning).to include(kind: "acknowledge", status: "needs_review", acknowledgement_stale: false)

    YearEndAcknowledgement.create!(company: company, tax_year: 2026, warning_code: "legacy_tax_bases", warning_digest: warning[:digest],
      note: "Reconciliation ties out", acknowledged_by: reviewer, acknowledged_by_name: reviewer.name,
      acknowledged_by_email: reviewer.email, acknowledged_by_role: reviewer.role, acknowledged_at: Time.current)
    expect(warnings(rows).fetch("legacy_tax_bases")).to include(status: "reviewed")

    rows.first[:source_summary][:cornerstone_payroll_item_count] = 4
    expect(warnings(rows).fetch("legacy_tax_bases")).to include(status: "needs_review", acknowledgement_stale: true)
  end

  it "applies the 2026 tip and overtime rules only from 2026" do
    rows = [ row(3, missing_tip_classification: true, missing_qualified_overtime: true, reported_tips_total: 50.0) ]

    expect(warnings(rows, year: 2026).keys).to include("tip_classification_unreviewed", "qualified_overtime_unreviewed", "tipped_occupation_code_missing")
    expect(warnings(rows, year: 2025).keys).to be_empty
  end

  it "asks for a comparison with filed returns when opening balances are in the W-2s" do
    reconciliation = {
      opening_balances: { present: true, first_pay_date: "2026-01-01", last_pay_date: "2026-06-30" },
      lines: [ { key: "social_security_wages", opening_balances: 12_000.0 } ]
    }

    warning = warnings([], reconciliation: reconciliation).fetch("opening_balances_compare_filed_returns")

    expect(warning).to include(kind: "acknowledge", status: "needs_review", period: [ "2026-01-01", "2026-06-30" ])
  end

  it "keeps the digest used by acknowledgements identical to the displayed warning" do
    rows = [ row(4, missing_qualified_overtime: true) ]
    service = described_class.new(company: company, year: 2026, w2_report: { employees: rows })

    expect(service.digests.fetch("qualified_overtime_unreviewed")).to eq(service.call.first[:digest])
  end
end
