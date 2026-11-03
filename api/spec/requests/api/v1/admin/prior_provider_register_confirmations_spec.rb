# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Prior-provider bulk register confirmation", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 11, 2, 2)) { example.run } }

  let(:path) { "/api/v1/admin/prior_provider_histories/draft/confirm_registers" }
  let(:acknowledgement) { PriorProviderHistory::RegisterConfirmation::ACKNOWLEDGEMENT }

  before do
    @company, @admin, @employees, @runs, @payload = history_fixture(period_count: 4)
    # Unchecked state: nothing matched yet and no references entered.
    @payload["periods"].each { |period| period["register_totals"] = {}; period["source_reference"] = "" }
    @payload["periods"].first["paychecks"].first["provider_payment_reference"] = "000123"
    @actor = @admin
    allow_any_instance_of(Api::V1::Admin::PriorProviderHistoriesController).to receive(:current_user) { @actor }
    allow_any_instance_of(Api::V1::Admin::PriorProviderHistoriesController).to receive(:current_company_id) { @company.id }
  end

  after do
    HistoricalImportSourceFile.where(company: @company).find_each { |file| R2StorageService.new.delete(file.storage_key) }
  end

  def confirmed(period_count: 4, paycheck_count: 12, gross_pay: "24000.00", net_pay: "19764.00")
    { period_count: period_count, paycheck_count: paycheck_count, gross_pay: gross_pay, net_pay: net_pay }
  end

  def save_draft(payload, lock_version = nil)
    put "/api/v1/admin/prior_provider_histories/draft", params: { payload: payload, step: 2, lock_version: lock_version }.compact, as: :json
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.dig("draft", "lock_version")
  end

  def confirm(payload, lock_version:, register_name: "ADP payroll register 2026", ack: acknowledgement, summary: confirmed)
    post path, params: { payload: payload, lock_version: lock_version, step: 2, register_name: register_name,
      acknowledgement: ack, confirmed: summary }.compact, as: :json
  end

  it "confirms every pay date under one attestation, keeps check references, and records it in the draft, audit and onboarding evidence" do
    version = save_draft(@payload)
    confirm(@payload, lock_version: version)
    expect(response).to have_http_status(:ok), response.body

    draft = PriorProviderHistoryDraft.find_by!(company: @company)
    expect(draft.updated_by).to eq(@admin)
    expect(response.parsed_body.dig("draft", "lock_version")).to eq(draft.lock_version)
    periods = draft.payload.fetch("periods")
    periods.each do |period|
      expect(period["source_reference"]).to eq("ADP payroll register 2026 — paid #{period['pay_date']}")
      expect(period["register_totals"]).to eq(
        "gross_pay" => "6000.00", "federal_income_tax" => "600.00", "social_security_tax" => "372.00", "medicare_tax" => "87.00",
        "deductions" => "0.00", "net_pay" => "4941.00", "employer_taxes" => "459.00", "employer_contributions" => "0.00"
      )
    end
    expect(periods.first["paychecks"].first["provider_payment_reference"]).to eq("000123")

    attestation = draft.payload.fetch("register_attestations").sole
    expect(attestation).to include(
      "actor_id" => @admin.id, "actor_name" => @admin.name, "attested_at" => "2026-11-02T02:00:00Z", "acknowledgement" => acknowledgement,
      "period_count" => 4, "paycheck_count" => 12, "gross_pay" => "24000.00", "net_pay" => "19764.00",
      "register_name" => "ADP payroll register 2026", "period_keys" => @payload["periods"].map { |period| period["key"] },
      "statement" => "I confirm these 4 pay dates / 12 paychecks totaling $24,000.00 gross / $19,764.00 net match the previous provider’s paid registers."
    )
    audit = AuditLog.find_by!(action: "prior_provider_histories#confirm_registers", company_id: @company.id)
    expect(audit.user_id).to eq(@admin.id)
    expect(audit.record_id).to eq(draft.id)
    expect(audit.metadata).to include("period_count" => 4, "paycheck_count" => 12, "gross_pay" => "24000.00", "net_pay" => "19764.00")

    # A draft save can neither drop nor forge the server-owned attestation.
    stored = draft.payload.fetch("register_attestations")
    forged = draft.payload.merge("register_attestations" => [ { "actor_id" => 0 } ])
    save_draft(forged, draft.lock_version)
    expect(draft.reload.payload.fetch("register_attestations")).to eq(stored)
    save_draft(draft.payload.except("register_attestations"), draft.lock_version)
    expect(draft.reload.payload.fetch("register_attestations")).to eq(stored)

    # The confirmed draft records exactly as individual matches do, with no payment effects.
    post "/api/v1/admin/prior_provider_histories/preview", params: { payload: draft.payload }, as: :json
    expect(response.parsed_body).to include("ready" => true, "errors" => [])
    post "/api/v1/admin/prior_provider_histories", params: { payload: draft.payload.to_json, preview_digest: response.parsed_body["digest"],
      idempotency_key: "bulk-confirm-2026", files: [ history_upload ], acknowledgement: PriorProviderHistory::Conversion::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:created), response.body
    onboarding = PriorProviderHistoryOnboarding.find_by!(company: @company)
    expect(onboarding.evidence.fetch("register_attestations")).to eq(stored)
    expect(HistoricalPaycheck.where(company: @company).count).to eq(12)
    expect(HistoricalPaycheck.where(company: @company).sum(:gross_pay)).to eq(24_000)
    expect(@company.reload.next_check_number).to eq(701)
    expect(PayrollItem.where(company: @company).where.not(check_number: nil)).to be_empty
    expect(PayrollLiabilityPosting.where(company: @company)).to be_empty
  end

  it "refuses the whole confirmation, naming each failing pay date and why, and saves nothing" do
    version = save_draft(@payload)
    before = PriorProviderHistoryDraft.find_by!(company: @company).payload
    first, second, third, fourth = @payload["periods"]
    first["register_totals"] = { "gross_pay" => "5999.00" }
    second["paychecks"].first["net_pay"] = "1.00"
    third["paychecks"].first["fit_taxable_wages"] = ""
    fourth["pay_date"] = "2026-02-30"
    confirm(@payload, lock_version: version)

    expect(response).to have_http_status(:unprocessable_entity)
    failures = response.parsed_body.fetch("failures")
    expect(failures.map { |row| row["key"] }).to eq(@payload["periods"].map { |period| period["key"] })
    expect(failures[0]["reasons"]).to eq([ "Doesn't match the register gross pay (register 5999.00, paychecks 6000.00)" ])
    expect(failures[1]["reasons"].sole).to end_with("Gross less employee taxes and deductions must equal net")
    expect(failures[2]["reasons"].sole).to match(/Fit taxable wages requires a nonnegative amount.*confirm zero explicitly/)
    expect(failures[3]["reasons"]).to eq([ "Needs real start, end and pay dates" ])
    expect(response.parsed_body["error"]).to eq("4 pay dates need individual review before confirming all")
    expect(PriorProviderHistoryDraft.find_by!(company: @company).payload).to eq(before)
    expect(AuditLog.where(action: "prior_provider_histories#confirm_registers")).to be_empty
  end

  it "requires a reference for every date unless the register name fills the blanks" do
    version = save_draft(@payload)
    confirm(@payload, lock_version: version, register_name: nil)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("failures").map { |row| row["reasons"] }.uniq).to eq([ [ "Needs a register reference (enter the register name above to fill it)" ] ])
    @payload["periods"].each { |period| period["source_reference"] = "Own page #{period['pay_date']}" }
    confirm(@payload, lock_version: version, register_name: nil)
    expect(response).to have_http_status(:ok), response.body
    expect(PriorProviderHistoryDraft.find_by!(company: @company).payload["periods"].map { |period| period["source_reference"] })
      .to eq(@payload["periods"].map { |period| period["source_reference"] })
  end

  it "refuses changed totals, a missing attestation, a stale draft and staff without access" do
    version = save_draft(@payload)
    confirm(@payload, lock_version: version, summary: confirmed(gross_pay: "23999.99"))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("changed after you reviewed them")
    confirm(@payload, lock_version: version, ack: nil)
    expect(response).to have_http_status(:unprocessable_entity)
    confirm(@payload, lock_version: version.to_i - 1)
    expect(response).to have_http_status(:conflict)
    @actor = create(:user, company: create(:company), role: "accountant")
    confirm(@payload, lock_version: version)
    expect(response).to have_http_status(:forbidden)
    expect(PriorProviderHistoryDraft.find_by!(company: @company).payload.key?("register_attestations")).to be(false)
    expect(AuditLog.where(action: "prior_provider_histories#confirm_registers")).to be_empty
  end
end
