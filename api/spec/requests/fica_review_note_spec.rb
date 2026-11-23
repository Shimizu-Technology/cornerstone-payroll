# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Annual FICA review disclosure", type: :request do
  include FicaHistoryHelpers

  let!(:tax_table) { create(:tax_table, tax_year: 2026, ss_wage_base: 184500) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:employee) do
    create(:employee, company: company, department: create(:department, company: company),
      first_name: "Maya", last_name: "Cruz", pay_rate: 15, hire_date: "2026-01-01", payment_delivery_method: "paper_check")
  end
  let(:batch) { create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current) }
  let(:run) do
    create(:pay_period, company: company, start_date: "2026-10-16", end_date: "2026-10-31", pay_date: "2026-11-15")
  end
  let!(:item) { create(:payroll_item, company: company, employee: employee, pay_period: run, hours_worked: 0, bonus: 450, reported_tips: 50) }

  before do
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(actor.id)
  end

  def calculate
    post "/api/v1/admin/pay_periods/#{run.id}/run_payroll", params: { employee_ids: [ employee.id ] }
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload.status).to eq("calculated"), response.body
    JSON.parse(response.body).fetch("pay_period")
  end

  def fica_amounts
    item.reload.attributes.slice("social_security_tax", "employer_social_security_tax", "medicare_tax", "employer_medicare_tax", "additional_medicare_tax")
  end

  def verified_empty_history
    prior = create(:pay_period, :committed, company: company, start_date: "2026-09-01", end_date: "2026-09-14", pay_date: "2026-09-24")
    empty = create(:payroll_item, company: company, employee: employee, pay_period: prior, hours_worked: 0,
      gross_pay: 0, net_pay: 0, tax_rule_snapshot: {})
    PayrollItemLegacyDisposition.create!(payroll_item: empty, company: company, created_by: actor,
      reason: PayrollItemLegacyDisposition::REASON, evidence_digest: "a" * 64)
    EmployeeYearFicaSourceReview.record!(employee: employee, actor: actor, tax_year: 2026, through_pay_date: "2026-12-31",
      external_ss_wage_bound: 0, external_medicare_wage_bound: 0, review_reference: "Synthetic complete source review")
    empty
  end

  it "excludes run-75-shaped verified-empty history without changing any FICA component" do
    calculate
    before_amounts = fica_amounts
    expect(before_amounts).to include("social_security_tax" => 31.to_d, "medicare_tax" => "7.25".to_d)
    empty = verified_empty_history
    saved_history = empty.reload.attributes
    payload = calculate
    expect(fica_amounts).to eq(before_amounts)
    expect(item.tax_rule_snapshot.fetch("annual_fica_context")).not_to have_key("history_review_open")
    expect(payload["annual_fica_review_note"]).to be_nil
    expect(payload["annual_fica_review"]).to be_nil
    expect(payload.fetch("compliance_warnings").join).not_to include("filing review", "Prior-period")
    context = BelowThresholdFicaContext.new(employee: employee, company: company, year: 2026, excluding_pay_period_id: run.id)
    expect(context.applicable?).to be(false)
    expect(context.unresolved_history?).to be(false)
    expect(empty.reload.attributes).to eq(saved_history)
  end

  it "clears the note for reconciled imported history with an applied bridge and verified-empty native item" do
    empty = verified_empty_history
    opening(gross: 11000)
    imports = Array.new(11) { imported }
    reconciliation = ImportedPaycheckFicaReconciliation.new(company: company, year: 2026)
    plan = reconciliation.inventory
    expect(reconciliation.apply!(actor: actor, review_reference: "Reviewed production-shaped synthetic imports",
      expected_digest: plan.fetch(:plan_digest))[:applied_proofs]).to eq(11)
    rules = PayrollFicaLegacyRecovery.new(company: company, year: 2026).verified_year_rules
    imports.each do |row|
      expect(ImportedPaycheckFicaEvidence.verified_bases(row.reload, rules: rules, year: 2026)).to be_present
    end
    ordinary = EmployeeYearFicaContext.new(employee: employee, year: 2026, excluding_pay_period_id: run.id)
      .increment(wages_delta: 500, tips_delta: 50, rules: rules)
    history = [ empty, *imports ].to_h { |row| [ row, row.reload.attributes ] }

    payload = calculate
    expect(item.reload.attributes.symbolize_keys.slice(*ordinary.keys)).to eq(ordinary)
    expect(item.tax_rule_snapshot.fetch("annual_fica_context")).not_to have_key("history_review_open")
    expect(payload["annual_fica_review_note"]).to be_nil
    expect(run.annual_fica_review_note).to be_nil
    expect(payload.fetch("compliance_warnings").join).not_to include("filing review", "Prior-period", "imported paycheck history")
    context = BelowThresholdFicaContext.new(employee: employee, company: company, year: 2026, excluding_pay_period_id: run.id)
    expect(context.applicable?).to be(true)
    expect(context.unresolved_history?).to be(false)
    # The same conservative proof is available; it must not replace the ordinary snapshot.
    expect(context.snapshot(current_item: item, rules: rules)).to include("history_review_open" => true)

    post "/api/v1/admin/pay_periods/#{run.id}/approve"
    expect(response).to have_http_status(:ok), response.body
    post "/api/v1/admin/pay_periods/#{run.id}/commit"
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload).to be_committed
    expect(run.annual_fica_review_note).to be_nil
    expect(item.reload.attributes.symbolize_keys.slice(*ordinary.keys)).to eq(ordinary)
    history.each { |row, attributes| expect(row.reload.attributes).to eq(attributes) }
  end

  it "renders older committed snapshots with a missing note using a named fallback" do
    item.update_columns(tax_rule_snapshot: { "annual_fica_context" => { "history_review_open" => true } })
    run.update_columns(status: "committed")
    expect(run.annual_fica_review_note).to eq("#{employee.full_name}: #{BelowThresholdFicaContext::NOTE}")
    expect(run.compliance_warnings).to include(run.annual_fica_review_note)
  end

  it "names only affected workers and preserves each stored reason" do
    item.update_columns(tax_rule_snapshot: { "annual_fica_context" => { "history_review_open" => true, "note" => "Voided pay period #75 needs review." } })
    other = create(:employee, company: company, first_name: "Noah", last_name: "Reyes")
    create(:payroll_item, company: company, employee: other, pay_period: run,
      tax_rule_snapshot: { "annual_fica_context" => { "history_review_open" => true, "note" => "Reversed paycheck #412 needs review." } })
    unaffected = create(:employee, company: company, first_name: "Unchanged", last_name: "Worker")
    create(:payroll_item, company: company, employee: unaffected, pay_period: run)
    note = run.annual_fica_review_note
    expect(note).to include("Maya Cruz: Voided pay period #75", "Noah Reyes: Reversed paycheck #412")
    expect(note).not_to include(unaffected.full_name, "imported paycheck history")
    expect(run.compliance_warnings).to include(note)

    get "/api/v1/admin/pay_periods/#{run.id}"
    expect(response).to have_http_status(:ok), response.body
    payload = response.parsed_body.fetch("pay_period")
    expect(payload.fetch("annual_fica_review")).to eq(
      "employee_count" => 2,
      "entries" => [
        { "employee_name" => "Maya Cruz", "note" => "Voided pay period #75 needs review." },
        { "employee_name" => "Noah Reyes", "note" => "Reversed paycheck #412 needs review." }
      ]
    )
    expect(payload.fetch("annual_fica_review_path")).to eq("/companies/#{company.id}/year-end?year=2026#payroll-history-review")
    expect(payload.fetch("annual_fica_review_note")).to eq(note)
    expect(payload.fetch("compliance_warnings")).to include(note)
  end

  it "keeps the notice without linking to a year the checklist cannot display" do
    run.update_columns(start_date: Date.new(2025, 10, 16), end_date: Date.new(2025, 10, 31), pay_date: Date.new(2025, 11, 15))
    item.update_columns(tax_rule_snapshot: { "annual_fica_context" => { "history_review_open" => true } })

    get "/api/v1/admin/pay_periods/#{run.id}"

    expect(response).to have_http_status(:ok), response.body
    payload = response.parsed_body.fetch("pay_period")
    expect(payload.fetch("annual_fica_review")).to include("employee_count" => 1)
    expect(payload.fetch("annual_fica_review_path")).to be_nil
  end

  it "clears the old false note after rolling back approval and recalculating, retaining all amounts" do
    verified_empty_history
    calculate
    saved_amounts = fica_amounts
    # A pre-fix approved run retained this legacy snapshot and generic note.
    old = { "version" => 1, "mode" => BelowThresholdFicaContext::MODE, "year" => 2026,
      "employee_id" => employee.id, "history_review_open" => true, "filing_review_open" => true,
      "note" => BelowThresholdFicaContext::NOTE }
    item.update_columns(tax_rule_snapshot: item.tax_rule_snapshot.merge("annual_fica_context" => old))
    run.update_columns(status: "approved", approved_at: Time.current, approved_by_id: actor.id)
    expect(run.annual_fica_review_note).to include(employee.full_name, BelowThresholdFicaContext::NOTE)
    post "/api/v1/admin/pay_periods/#{run.id}/unapprove"
    expect(response).to have_http_status(:ok), response.body
    expect(calculate["annual_fica_review_note"]).to be_nil
    expect(fica_amounts).to eq(saved_amounts)
    post "/api/v1/admin/pay_periods/#{run.id}/approve"
    expect(response).to have_http_status(:ok), response.body
    post "/api/v1/admin/pay_periods/#{run.id}/commit"
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload).to be_committed
    expect(run.annual_fica_review_note).to be_nil
    expect(fica_amounts).to eq(saved_amounts)
  end
end
