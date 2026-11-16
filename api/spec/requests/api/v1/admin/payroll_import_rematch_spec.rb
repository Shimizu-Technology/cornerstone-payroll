# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Matching a MoSa import again after a worker returns", type: :request do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:staff) { create(:user, company: company, role: "admin") }
  let!(:avery) { create(:employee, company: company, first_name: "Avery", last_name: "Example", pay_rate: 10) }
  let!(:blake) { create(:employee, company: company, first_name: "Blake", last_name: "Returning", pay_rate: 12, status: "inactive") }
  let!(:run) { create(:pay_period, company: company) }
  let(:url) { "/api/v1/admin/pay_periods/#{run.id}" }
  let(:objects) { {} }
  let(:storage) do
    entries = objects
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| entries[key] = data }
      store.define_singleton_method(:download_with_limit) { |key, **| entries.fetch(key) }
      store.define_singleton_method(:delete) { |key| entries.delete(key) }
    end
  end

  before do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: run.pay_date.year)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    allow(R2StorageService).to receive(:new).and_return(storage)
    CompanyWorkweek.create!(company: company, starts_on_weekday: run.start_date.wday, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: run.start_date, source: "operator_confirmed", confirmation_status: "confirmed",
      confirmed_by: staff, confirmed_at: Time.current, notes: "Synthetic confirmed workweek")
  end

  def preview!
    bytes = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 },
      { name: "Returning, Blake", regular_hours: 12, regular_pay: 144 } ], period_start: run.start_date, period_end: run.end_date))
    post "#{url}/preview_import", params: {
      pdf_file: portal_upload("revel.pdf", bytes, "application/pdf"), excel_file: portal_upload("changes.xlsx",
        PayrollImport::MosaSupplementalTemplate.new(run).generate, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
      tips_paid_out_from_tips: true
    }
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def blake_row(data) = data.dig("preview", "source_rows").find { |row| row["source_employee_name"] == "Returning, Blake" }

  it "matches the same files again after reactivation and the returning worker is ready to apply" do
    first = preview!
    expect(blake_row(first)).to include("row_kind" => "unmatched_revel", "employee_id" => nil)
    expect(blake_row(first)["errors"].sole).to include("employee_id" => blake.id, "employee_name" => "Blake Returning",
      "employee_status" => "inactive", "message" => "Blake Returning is inactive in Cornerstone.")
    expect(first.fetch("pay_period")).to eq("start_date" => run.start_date.iso8601, "end_date" => run.end_date.iso8601)

    post "#{url}/rematch_import"
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body["import_id"]).to eq(first["import_id"])

    EmployeeStatusTransitionService.reactivate!(employee: blake, actor: staff, attributes: { effective_date: run.start_date.iso8601 })
    post "#{url}/rematch_import"

    expect(response).to have_http_status(:ok), response.body
    second = response.parsed_body
    expect(second.dig("source_package", "package_revision")).to eq(2)
    expect(second.dig("source_package", "supersession_reason")).to eq("Matched the same files again after the employee list changed")
    expect(second.dig("source_package", "sources").map { |source| source["present"] }).to all(be(true))
    # The review compares these to keep row outcomes only for the same files.
    fingerprints = ->(data) { data.dig("source_package", "documents").to_h { |document| [ document["source_role"], document["sha256"] ] } }
    expect(fingerprints.call(second).keys).to contain_exactly("revel_hours", "supplemental_workbook")
    expect(fingerprints.call(second).values).to all(match(/\A\h{64}\z/))
    expect(fingerprints.call(second)).to eq(fingerprints.call(first))
    expect(blake_row(second)).to include("row_kind" => "matched", "employee_id" => blake.id, "errors" => [])
    expect(second.dig("preview", "tips_paid_out_from_tips")).to be(true)

    rows = second.dig("preview", "source_rows").map { |row| { id: row["id"], disposition: "included" } }
    post "#{url}/apply_import", params: { import_id: second["import_id"], rows: rows }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(run.payroll_items.find_by!(employee: blake).hours_worked).to eq(12)
  end

  it "refuses once the review was applied" do
    data = preview!
    rows = data.dig("preview", "source_rows").map { |row| { id: row["id"], disposition: row["row_kind"] == "matched" ? "included" : "informational", disposition_reason: "Not paid here" } }
    post "#{url}/apply_import", params: { import_id: data["import_id"], rows: rows }, as: :json
    expect(response).to have_http_status(:ok), response.body

    post "#{url}/rematch_import"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Only an import still in review can be matched again. Upload corrected files instead.")
  end
end
