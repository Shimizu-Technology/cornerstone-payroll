# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::PayPeriods", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:company) { create(:company, name: "Portal Payroll Co") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "portal-pay-periods@example.com") }
  let!(:committed_pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 18))
  end
  let!(:draft_pay_period) do
    create(:pay_period,
      company: company,
      status: "draft",
      start_date: Date.new(2026, 4, 15),
      end_date: Date.new(2026, 4, 28),
      pay_date: Date.new(2026, 5, 2))
  end

  before do
    ensure_verified_test_tax_years(2024, 2026)
    CompanyAssignment.create!(user: client_user, company: company)
    create(:employee, company: company, first_name: "Nina", last_name: "Cruz")
    create(:payroll_item, pay_period: committed_pay_period, company: company, gross_pay: 1000, net_pay: 810)
    create(:payroll_item, pay_period: draft_pay_period, company: company, gross_pay: 900, net_pay: 730)

    [
      Api::V1::Client::PayPeriodsController,
      Api::V1::Client::ImportedPayPeriodsController
    ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  def create_imported_payroll(company:, status: "locked", suffix: "client", pay_date: Date.new(2026, 3, 20), locked_at: Time.zone.parse("2026-03-21 09:00"))
    employee = company.employees.first || create(:employee, company: company)
    batch = HistoricalImportBatch.create!(
      company: company,
      source_label: "QuickBooks #{suffix}",
      bundle_digest: "client-pay-periods-#{company.id}-#{suffix}",
      importer_version: "quickbooks-online-payroll-v5",
      status: status,
      locked_at: status == "locked" ? locked_at : nil,
      locked_by: status == "locked" ? client_user : nil
    )
    period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "period-#{suffix}",
      source_label: "Payroll #{suffix}",
      start_date: pay_date - 13.days,
      end_date: pay_date - 5.days,
      pay_date: pay_date,
      paycheck_count: 1,
      totals: { "gross_pay" => "875.25", "net_pay" => "701.10" }
    )
    worker = HistoricalWorker.create!(
      historical_import_batch: batch,
      company: company,
      employee: employee,
      external_key: "worker-#{suffix}",
      source_name: "Nina Cruz",
      normalized_name: "nina cruz",
      source_status: "active",
      mapping_status: "exact_match"
    )
    paycheck = HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "check-#{suffix}",
      source_employee_name: "Nina Cruz",
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      check_number: "QB-401",
      payment_method: "Direct deposit",
      hours_total: 72,
      gross_pay: 875.25,
      employee_taxes: 124.15,
      federal_income_tax: 70,
      social_security_tax: 45,
      medicare_tax: 9.15,
      after_tax_deductions: 50,
      net_pay: 701.10,
      source_metadata: { "private_note" => "never expose this" }
    )
    [ batch, period, paycheck ]
  end

  it "surfaces an open period without disclosing its unpublished payroll" do
    today = PayrollSubmissions::Catalog.today
    draft_pay_period.update!(start_date: today - 13.days, end_date: today, pay_date: today + 5.days)

    get "/api/v1/client/pay_periods"

    expect(response).to have_http_status(:ok)
    open_period = response.parsed_body.fetch("open_period")
    expect(open_period).to eq(
      "ref" => "#{draft_pay_period.start_date}_#{draft_pay_period.end_date}",
      "start_date" => draft_pay_period.start_date.iso8601,
      "end_date" => draft_pay_period.end_date.iso8601,
      "pay_date" => draft_pay_period.pay_date.iso8601,
      "client_payroll_status" => "preparing"
    )
    expect(response.parsed_body.fetch("pay_periods").pluck("id")).not_to include(draft_pay_period.id)
  end

  it "offers a derived period with a manual pay date" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      CompanyPaySchedule.create!(company: company, frequency: "semimonthly", period_rule: "semimonthly",
        pay_date_rule: "manual", timezone: "Pacific/Guam", source: "operator_confirmed",
        confirmation_status: "needs_confirmation", effective_on: Date.new(2026, 1, 1))

      get "/api/v1/client/pay_periods"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("open_period")).to include(
        "end_date" => "2026-11-15", "pay_date" => nil, "client_payroll_status" => "preparing")
    end
  end

  it "does not offer a submission period linked to a voided run as open" do
    today = PayrollSubmissions::Catalog.today
    run = create(:pay_period, :committed, company: company, start_date: today - 13.days,
      end_date: today, pay_date: today + 5.days)
    PayrollSubmissionPeriod.create!(company: company, pay_period: run, start_date: run.start_date,
      end_date: run.end_date, pay_date: run.pay_date, source: "pay_period", status: "paid")
    run.update_column(:correction_status, "voided")

    get "/api/v1/client/pay_periods"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("open_period")).to be_nil
  end

  it "shows only reportable Cornerstone payrolls and locked QuickBooks payrolls" do
    _batch, imported_period, = create_imported_payroll(company: company)
    create_imported_payroll(company: company, status: "applied", suffix: "not-locked")
    hidden_void = create(:pay_period, :committed, company: company, correction_status: "voided")

    get "/api/v1/client/pay_periods"

    expect(response).to have_http_status(:ok)
    records = response.parsed_body.fetch("pay_periods")
    expect(records.map { |record| record.fetch("key") }).to contain_exactly(
      "native:#{committed_pay_period.id}",
      "imported:#{imported_period.id}"
    )
    expect(records.map { |record| record.fetch("key") }).not_to include("native:#{hidden_void.id}")
    expect(records.find { |record| record.fetch("record_type") == "imported" }).to include(
      "status" => "locked",
      "total_gross" => 875.25,
      "total_net" => 701.1,
      "capabilities" => include("view" => true, "edit" => false, "delete" => false, "run" => false)
    )
    expect(response.parsed_body.dig("meta", "statuses")).to eq("committed" => 1, "locked" => 1)
  end

  it "keeps staff pay period notes out of the client detail" do
    committed_pay_period.update_columns(notes: "TEST ONLY - staff note")
    get "/api/v1/client/pay_periods/#{committed_pay_period.id}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("pay_period")).not_to have_key("notes")
    expect(response.body).not_to include("TEST ONLY - staff note")
  end

  it "orders payroll history newest first" do
    march_period = create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 3, 16),
      end_date: Date.new(2026, 3, 31),
      pay_date: Date.new(2026, 4, 20))
    earlier_march_period = create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 15),
      pay_date: Date.new(2026, 3, 30))

    get "/api/v1/client/pay_periods"

    ids = response.parsed_body.fetch("pay_periods").map { |pay_period| pay_period.fetch("id") }
    expect(ids).to eq([ committed_pay_period.id, march_period.id, earlier_march_period.id ])
  end

  it "returns explicit instants for native and imported processing times" do
    committed_at = Time.utc(2026, 11, 22, 7, 0, 1, 123456)
    committed_pay_period.update!(committed_at: committed_at)
    locked_at = Time.utc(2026, 3, 21, 9, 0, 0, 654321)
    _batch, imported_period, = create_imported_payroll(company: company, suffix: "processing-time", locked_at: locked_at)
    ActiveRecord::Base.connection.execute("SET LOCAL TIME ZONE 'Pacific/Guam'")

    get "/api/v1/client/pay_periods"

    expect(response).to have_http_status(:ok)
    records = response.parsed_body.fetch("pay_periods").index_by { |record| record.fetch("key") }
    {
      "native:#{committed_pay_period.id}" => committed_at,
      "imported:#{imported_period.id}" => locked_at
    }.each do |key, expected|
      timestamp = records.fetch(key).fetch("processed_at")
      expect(timestamp).to match(/(?:Z|[+-]\d{2}:\d{2})\z/)
      expect(Time.iso8601(timestamp)).to eq(expected)
    end
  end

  it "shows a safe read-only QuickBooks payroll detail" do
    _batch, imported_period, paycheck = create_imported_payroll(company: company, suffix: "detail")

    get "/api/v1/client/imported_pay_periods/#{imported_period.id}"

    expect(response).to have_http_status(:ok), response.body
    body = response.parsed_body
    expect(body.dig("data", "key")).to eq("imported:#{imported_period.id}")
    expect(body.dig("data", "capabilities")).to include(
      "view" => true,
      "edit" => false,
      "delete" => false,
      "run" => false,
      "commit" => false
    )
    expect(body.dig("data", "paychecks").sole).to include(
      "id" => paycheck.id,
      "historical_pay_period_id" => imported_period.id,
      "historical_worker_id" => paycheck.historical_worker_id,
      "employee_name" => "Nina Cruz",
      "pay_date" => imported_period.pay_date.iso8601,
      "period_type" => "regular",
      "payment_method" => "Direct deposit",
      "check_number" => nil
    )
    expect(body.dig("data", "source")).not_to have_key("import_batch_id")
    expect(body.dig("data", "source")).not_to have_key("importer_version")
    expect(body.dig("data", "source")).not_to have_key("locked_by_name")
    expect(response.body).not_to include("QB-401", "private_note", "never expose this")
  end

  it "does not expose unlocked or another company's imported payroll" do
    _batch, applied_period, = create_imported_payroll(company: company, status: "applied", suffix: "applied-detail")
    other_company = create(:company)
    _other_batch, other_period, = create_imported_payroll(company: other_company, suffix: "other-company")

    get "/api/v1/client/imported_pay_periods/#{applied_period.id}"
    expect(response).to have_http_status(:not_found)

    get "/api/v1/client/imported_pay_periods/#{other_period.id}"
    expect(response).to have_http_status(:not_found)
  end

  it "returns not found for a non-numeric imported payroll id" do
    get "/api/v1/client/imported_pay_periods/not-a-number"

    expect(response).to have_http_status(:not_found)
  end

  it "does not allow a client to open a draft pay period detail" do
    get "/api/v1/client/pay_periods/#{draft_pay_period.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => "Pay period not found")
  end

  it "shows an approved review revision and lets the assigned client approve only that revision" do
    company.update!(client_payroll_approval_required: true)
    draft_pay_period.update!(status: "calculated", calculated_at: Time.current)
    review_package = PayrollReview::RevisionService.new(pay_period: draft_pay_period, actor: nil).issue!
    draft_pay_period.update!(status: "approved")
    PayrollReview::RevisionService.new(pay_period: draft_pay_period).publish!

    get "/api/v1/client/pay_periods"
    expect(response.parsed_body.fetch("pay_periods").map { |record| record.fetch("key") })
      .to include("native:#{draft_pay_period.id}")

    get "/api/v1/client/pay_periods/#{draft_pay_period.id}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("pay_period", "payroll_review")).to include(
      "revision" => 1,
      "status" => "pending",
      "checksum_short" => review_package.calculation_checksum.first(12)
    )
    expect(response.parsed_body.dig("pay_period", "payroll_items", 0)).to include(
      "gross_pay" => "900.0",
      "net_pay" => "730.0"
    )

    post "/api/v1/client/pay_periods/#{draft_pay_period.id}/approve_review", params: {
      revision_id: review_package.id,
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT,
      notes: "Reviewed against our submitted hours."
    }

    expect(response).to have_http_status(:ok), response.body
    expect(review_package.reload).to have_attributes(
      status: "approved",
      approved_by: client_user,
      approval_recorded_by: client_user,
      approval_method: "client_portal"
    )
  end

  it "exposes pay type metadata from snapshot and other_deductions so client row columns reconcile with total_deductions" do
    salaried = create(:employee, company: company, first_name: "Sam", last_name: "Salary",
      employment_type: "salary", salary_type: "annual", pay_rate: 68_000)
    item = create(:payroll_item,
      pay_period: committed_pay_period,
      company: company,
      employee: salaried,
      employment_type: "salary",
      pay_rate: 68_000,
      calculation_context_snapshot: { "employee" => { "salary_type" => "annual" } },
      hours_worked: 0,
      gross_pay: 2615.38,
      withholding_tax: 220,
      additional_withholding: 10,
      social_security_tax: 162.15,
      medicare_tax: 37.92,
      retirement_payment: 100,
      roth_retirement_payment: 25,
      loan_payment: 50,
      insurance_payment: 40,
      custom_deductions: [ { "label" => "Uniform", "amount" => 15.0 } ],
      total_deductions: 660.07,
      net_pay: 1955.31)

    get "/api/v1/client/pay_periods/#{committed_pay_period.id}"

    expect(response).to have_http_status(:ok)
    row = response.parsed_body.dig("pay_period", "payroll_items").find { |entry| entry["id"] == item.id }
    expect(row).to include(
      "employment_type" => "salary",
      "salary_type" => "annual",
      "additional_withholding" => "10.0",
      "other_deductions" => "15.0",
      "total_deductions" => "660.07"
    )
    sum = row.values_at("withholding_tax", "additional_withholding", "social_security_tax", "medicare_tax",
      "retirement_payment", "roth_retirement_payment", "loan_payment", "insurance_payment", "other_deductions")
      .sum(&:to_d)
    expect(sum).to eq(row["total_deductions"].to_d)
  end

  it "preserves signed deduction refunds on corrective checks even when total_deductions is positive" do
    worker = create(:employee, company: company, first_name: "Dana", last_name: "Delta",
      employment_type: "hourly", pay_rate: 20)
    item = create(:payroll_item,
      pay_period: committed_pay_period,
      company: company,
      employee: worker,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 10,
      gross_pay: 200.00,
      withholding_tax: 41.49,
      social_security_tax: 12.40,
      medicare_tax: 2.90,
      custom_deductions: [ { "label" => "Uniform refund", "amount" => -10.0 } ],
      total_deductions: 46.79,
      net_pay: 153.21)

    get "/api/v1/client/pay_periods/#{committed_pay_period.id}"

    expect(response).to have_http_status(:ok)
    row = response.parsed_body.dig("pay_period", "payroll_items").find { |entry| entry["id"] == item.id }
    expect(row["other_deductions"].to_d).to eq(-10.0.to_d)
    expect(row["total_deductions"].to_d).to eq(46.79.to_d)
    sum = row.values_at("withholding_tax", "additional_withholding", "social_security_tax", "medicare_tax",
      "retirement_payment", "roth_retirement_payment", "loan_payment", "insurance_payment", "other_deductions")
      .sum(&:to_d)
    expect(sum).to eq(row["total_deductions"].to_d)
    expect(row["gross_pay"].to_d - row["total_deductions"].to_d + row["non_taxable_additions_total"].to_d).to eq(row["net_pay"].to_d)
  end

  it "buckets deduplicated payroll fields and non-taxable additions to match the stub and reports" do
    worker = create(:employee, company: company, first_name: "Alex", last_name: "Fields",
      employment_type: "hourly", pay_rate: 22.5)
    retirement_def = PayrollFieldDefinition.create!(
      company: company, name: "401(k) Pre-Tax", kind: "deduction", tax_treatment: "pre_tax_deduction",
      category: "retirement", reporting_group: "401k_pre_tax", amount_type: "fixed"
    )
    insurance_def = PayrollFieldDefinition.create!(
      company: company, name: "Health Premium", kind: "deduction", tax_treatment: "pre_tax_deduction",
      category: "insurance", amount_type: "fixed"
    )
    garnishment_def = PayrollFieldDefinition.create!(
      company: company, name: "Wage Garnishment", kind: "deduction", tax_treatment: "post_tax_deduction",
      category: "garnishment", amount_type: "fixed"
    )
    reimb_def = PayrollFieldDefinition.create!(
      company: company, name: "Mileage Reimbursement", kind: "addition", tax_treatment: "non_taxable_addition",
      category: "reimbursement", amount_type: "fixed"
    )

    item = create(:payroll_item,
      pay_period: committed_pay_period,
      company: company,
      employee: worker,
      employment_type: "hourly",
      pay_rate: 22.5,
      hours_worked: 40,
      gross_pay: 900.00,
      withholding_tax: 39.30,
      social_security_tax: 55.80,
      medicare_tax: 13.05,
      retirement_payment: 0,
      roth_retirement_payment: 0,
      loan_payment: 0,
      insurance_payment: 0,
      total_deductions: 223.15,
      net_pay: 726.85)

    [
      [ retirement_def, "pre_tax", 45.0, "retirement", "401k_pre_tax" ],
      [ insurance_def, "pre_tax", 25.0, "insurance", nil ],
      [ garnishment_def, "post_tax", 45.0, "garnishment", nil ]
    ].each do |definition, ded_cat, amount, sub_cat, group|
      ded_type = DeductionType.create!(
        company: company, name: "Payroll Field: #{definition.name}", category: ded_cat,
        sub_category: sub_cat, reporting_group: group
      )
      entry = item.payroll_item_field_entries.create!(
        payroll_field_definition: definition,
        label: definition.name,
        kind: definition.kind,
        tax_treatment: definition.tax_treatment,
        category: definition.category,
        reporting_group: definition.reporting_group,
        amount: amount,
        active: true
      )
      deduction = item.payroll_item_deductions.create!(
        company_id: company.id,
        deduction_type: ded_type,
        amount: amount,
        category: ded_cat,
        label: definition.name,
        reporting_group: group
      )
      PayrollComponentMirrors.record!(entry, deduction)
      entry.save!
    end

    item.payroll_item_field_entries.create!(
      payroll_field_definition: reimb_def,
      label: reimb_def.name,
      kind: reimb_def.kind,
      tax_treatment: reimb_def.tax_treatment,
      category: reimb_def.category,
      amount: 50.0,
      active: true
    )

    get "/api/v1/client/pay_periods/#{committed_pay_period.id}"

    expect(response).to have_http_status(:ok)
    row = response.parsed_body.dig("pay_period", "payroll_items").find { |entry| entry["id"] == item.id }
    expect(row["retirement_payment"].to_d + row["roth_retirement_payment"].to_d).to eq(45.0.to_d)
    expect(row["insurance_payment"].to_d).to eq(25.0.to_d)
    expect(row["loan_payment"].to_d).to eq(0.0.to_d)
    expect(row["other_deductions"].to_d).to eq(45.0.to_d)
    expect(row["non_taxable_additions_total"].to_d).to eq(50.0.to_d)
    expect(row["total_deductions"].to_d).to eq(223.15.to_d)
    sum = row.values_at("withholding_tax", "additional_withholding", "social_security_tax", "medicare_tax",
      "retirement_payment", "roth_retirement_payment", "loan_payment", "insurance_payment", "other_deductions")
      .sum(&:to_d)
    expect(sum).to eq(row["total_deductions"].to_d)
    expect(row["gross_pay"].to_d - row["total_deductions"].to_d + row["non_taxable_additions_total"].to_d).to eq(row["net_pay"].to_d)
  end

  it "does not fall back to current employee pay basis when historical snapshot evidence is missing" do
    salaried = create(:employee, company: company, first_name: "Pat", last_name: "Legacy",
      employment_type: "salary", salary_type: "annual", pay_rate: 68_000)
    historical_item = create(:payroll_item,
      pay_period: committed_pay_period,
      company: company,
      employee: salaried,
      employment_type: "salary",
      pay_rate: 68_000,
      calculation_context_snapshot: {},
      timekeeping_context_snapshot: {},
      gross_pay: 2615.38,
      total_deductions: 500,
      net_pay: 2115.38)
    salaried.update_columns(salary_type: "per_period")

    get "/api/v1/client/pay_periods/#{committed_pay_period.id}"

    expect(response).to have_http_status(:ok)
    row = response.parsed_body.dig("pay_period", "payroll_items").find { |entry| entry["id"] == historical_item.id }
    expect(row["salary_type"]).to be_nil
    expect(row["contractor_pay_type"]).to be_nil
  end

  it "does not treat a receipt-only reply as payroll approval" do
    company.update!(client_payroll_approval_required: true)
    draft_pay_period.update!(status: "calculated", calculated_at: Time.current)
    review_package = PayrollReview::RevisionService.new(pay_period: draft_pay_period, actor: nil).issue!
    draft_pay_period.update!(status: "approved")
    PayrollReview::RevisionService.new(pay_period: draft_pay_period).publish!

    post "/api/v1/client/pay_periods/#{draft_pay_period.id}/approve_review", params: {
      revision_id: review_package.id,
      acknowledgement: "Received, thank you!"
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to match(/exact payroll revision/)
    expect(review_package.reload).to be_pending
  end
end
