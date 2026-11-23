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
    rows = [ row(2, missing_qualified_overtime: true) ]
    warning = warnings(rows).fetch("qualified_overtime_unreviewed")
    expect(warning).to include(kind: "acknowledge", status: "needs_review", acknowledgement_stale: false)

    YearEndAcknowledgement.create!(company: company, tax_year: 2026, warning_code: "qualified_overtime_unreviewed", warning_digest: warning[:digest],
      note: "Reconciliation ties out", acknowledged_by: reviewer, acknowledged_by_name: reviewer.name,
      acknowledged_by_email: reviewer.email, acknowledged_by_role: reviewer.role, acknowledged_at: Time.current)
    expect(warnings(rows).fetch("qualified_overtime_unreviewed")).to include(status: "reviewed")

    rows.first[:source_summary][:cornerstone_payroll_item_count] = 4
    expect(warnings(rows).fetch("qualified_overtime_unreviewed")).to include(status: "needs_review", acknowledgement_stale: true)
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

  describe "evidence bound to saved paycheck amounts" do
    let(:department) { create(:department, company: company) }
    let(:employee) { create(:employee, company: company, department: department) }
    let(:period) { create(:pay_period, :committed, company: company, start_date: Date.new(2026, 3, 16), end_date: Date.new(2026, 3, 31), pay_date: Date.new(2026, 4, 3)) }
    let!(:item) do
      create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 2_000, net_pay: 1_600,
        overtime_hours: 4, qualified_overtime_compensation: nil, withholding_tax: 150, social_security_tax: 124, medicare_tax: 29,
        social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000, fit_taxable_wages: 2_000)
    end

    def live_warnings(**options)
      described_class.new(company: company, year: 2026, w2_report: W2GuAggregator.new(company, 2026).generate, **options).call
        .index_by { |warning| warning[:code] }
    end

    def acknowledge(code, digest)
      YearEndAcknowledgement.create!(company: company, tax_year: 2026, warning_code: code, warning_digest: digest,
        note: "Reviewed", acknowledged_by: reviewer, acknowledged_by_name: reviewer.name,
        acknowledged_by_email: reviewer.email, acknowledged_by_role: reviewer.role, acknowledged_at: Time.current)
    end

    it "needs a new overtime review when the reviewed hours and gross change" do
      acknowledge("qualified_overtime_unreviewed", live_warnings.fetch("qualified_overtime_unreviewed")[:digest])
      expect(live_warnings.fetch("qualified_overtime_unreviewed")).to include(status: "reviewed")

      item.update_columns(overtime_hours: 40, gross_pay: 3_000, social_security_taxable_wages: 3_000, medicare_taxable_wages: 3_000, fit_taxable_wages: 3_000)

      expect(live_warnings.fetch("qualified_overtime_unreviewed")).to include(status: "needs_review", acknowledgement_stale: true)
    end

    it "needs a new overtime review when only the hours change" do
      acknowledge("qualified_overtime_unreviewed", live_warnings.fetch("qualified_overtime_unreviewed")[:digest])

      item.update_columns(overtime_hours: 40)

      expect(live_warnings.fetch("qualified_overtime_unreviewed")).to include(status: "needs_review", acknowledgement_stale: true)
    end

    def review_gap(item)
      admin = create(:user, company: company, role: "admin")
      PayrollHistoryReview::Resolution.new(company: company, tax_year: 2026,
      subject_key: PayrollHistoryReview::Subject.key_for(item).join("-"), user: admin, actor: AuditActor.for_user(admin))
        .resolve!(code: "legacy_basis_accepted", reference: "Legacy wages tie to the reconciliation", expected_digest: item.subject_digest).first
    end

    it "uses each employee's matching history decision for FIT- and Medicare-only legacy gaps" do
      item.update_columns(fit_taxable_wages: nil, additional_medicare_taxable_wages: 0)
      other = create(:employee, company: company, department: department)
      create(:payroll_item, company: company, employee: other, pay_period: period, gross_pay: 1000,
        social_security_taxable_wages: 1000, social_security_taxable_tips: 0, additional_medicare_taxable_wages: 0,
        fit_taxable_wages: 1000, medicare_taxable_wages: nil)
      report = W2GuAggregator.new(company, 2026).generate
      before_amounts = report.fetch(:employees).map { |row| row.values_at(:box1_wages_tips_other_comp, :box3_social_security_wages, :box5_medicare_wages_tips) }

      detector = PayrollHistoryReview::Detector.new(company: company, tax_year: 2026)
      gaps = detector.call(apply: true).fetch(:items).map(&:first).index_by(&:employee_id)
      expect(gaps.keys).to contain_exactly(employee.id, other.id)
      result = live_warnings.fetch("legacy_tax_bases")
      expect(result).to include(kind: "history_review", status: "needs_review", acknowledgement: nil)

      first = review_gap(gaps.fetch(employee.id))
      result = live_warnings.fetch("legacy_tax_bases")
      expect(result[:status]).to eq("needs_review")
      expect(result[:employees]).to contain_exactly(
        a_hash_including(employee_id: employee.id, history_review: { by: first.resolved_by.name, at: first.resolved_at }),
        a_hash_including(employee_id: other.id))

      review_gap(gaps.fetch(other.id))
      expect(live_warnings.fetch("legacy_tax_bases")[:status]).to eq("reviewed")
      after_amounts = W2GuAggregator.new(company, 2026).generate.fetch(:employees)
        .map { |row| row.values_at(:box1_wages_tips_other_comp, :box3_social_security_wages, :box5_medicare_wages_tips) }
      expect(after_amounts).to eq(before_amounts)

      item.update_columns(withholding_tax: 175)
      expect(live_warnings.fetch("legacy_tax_bases")[:status]).to eq("needs_review")
      expect(detector.call(apply: true).fetch(:counts)).to eq(reopened: 1, resolved: 1)
    end

    it "requires additional review if accepted legacy wages reach the cap or use a benefit rebuild" do
      item.update_columns(fit_taxable_wages: nil, additional_medicare_taxable_wages: 0)
      detector = PayrollHistoryReview::Detector.new(company: company, tax_year: 2026)
      review_gap(detector.call.fetch(:items).sole.first)
      report = W2GuAggregator.new(company, 2026).generate
      row = report.fetch(:employees).sole
      warning = -> { described_class.new(company: company, year: 2026, w2_report: report).call.find { |entry| entry[:code] == "legacy_tax_bases" } }

      expect(warning.call).to include(status: "reviewed")
      row[:box3_social_security_wages] = report.dig(:meta, :ss_wage_base) - 10
      row[:box7_social_security_tips] = 10
      expect(warning.call).to include(status: "needs_review", details: [ a_string_including("annual wage base") ])

      row[:box3_social_security_wages] = 2000
      row[:rebuild_ss] = true
      expect(warning.call).to include(status: "needs_review", details: [ a_string_including("Pre-tax benefits") ])
      expect(warning.call[:employees].sole).not_to have_key(:history_review)
    end

    it "keeps an Additional Medicare-only gap out of the W-2 missing bases warning" do
      item.update_columns(additional_medicare_taxable_wages: nil)
      detector = PayrollHistoryReview::Detector.new(company: company, tax_year: 2026)
      expect(detector.call(apply: true).fetch(:items).sole.first.subject_type).to eq("legacy_basis_gap")
      expect(live_warnings).not_to have_key("legacy_tax_bases")
    end

    it "needs a new employer-benefit review when a flagged paycheck's benefit amount or classification changes" do
      definition = create(:payroll_field_definition, :employer_contribution, company: company)
      entry = create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: definition, amount: 50)
      report = W2GuAggregator.new(company, 2026).generate
      report[:review_warnings] = [ { code: PayrollReportComponentReview::CODE, payroll_item_id: item.id, employee_id: employee.id } ]
      digest = -> { described_class.new(company: company, year: 2026, w2_report: report).digests.fetch(PayrollReportComponentReview::CODE) }
      reviewed = digest.call

      entry.update_columns(amount: 75)
      changed_amount = digest.call
      entry.update_columns(reporting_group: "health_insurance")

      expect(changed_amount).not_to eq(reviewed)
      expect(digest.call).not_to eq(changed_amount)
    end
  end

  it "asks for a review of a 941 recorded-liability residual and names the quarter" do
    reconciliation = { form_941_reviews: [
      { quarter: 2, status: "residual", recorded_liability_residual: 0.03, employee_difference: 0.0, message: "The Q2 941: recorded tax liability differs from line 6 by $0.03." }
    ] }

    warning = warnings([], reconciliation: reconciliation).fetch("form_941_liability_residual")

    expect(warning).to include(kind: "acknowledge", status: "needs_review", details: [ a_string_including("Q2 941") ])
  end

  it "binds a 941 residual review to the quarter's expected and recorded tax, not only the residual" do
    review = { quarter: 2, status: "residual", recorded_liability_residual: 0.03, employee_difference: 0.0,
               expected_employee_total: 153.0, recorded_employee_total: 153.0, recorded_employer_total: 153.03,
               recorded_total_liability: 306.03, line6_total_taxes: 306.0, message: "The Q2 941." }
    digest = ->(changes) { warnings([], reconciliation: { form_941_reviews: [ review.merge(changes) ] }).fetch("form_941_liability_residual")[:digest] }

    # Another ordinary paycheck in the quarter: same residual, larger totals.
    added_paycheck = { expected_employee_total: 306.0, recorded_employee_total: 306.0, recorded_employer_total: 306.03,
                       recorded_total_liability: 612.03, line6_total_taxes: 612.0 }

    expect(digest.call(added_paycheck)).not_to eq(digest.call({}))
  end
end
