# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MoSa import source files and re-import safeguards", type: :request do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:staff) { create(:user, company: company, role: "admin") }
  let!(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example", pay_rate: 10) }
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

  def pdf(hours = 40)
    bytes = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: hours, overtime_hours: 2, regular_pay: hours * 10 } ],
      period_start: run.start_date, period_end: run.end_date))
    portal_upload("payroll_#{run.start_date}_to_#{run.end_date}.pdf", bytes, "application/pdf")
  end

  def workbook
    portal_upload("changes.xlsx", PayrollImport::MosaSupplementalTemplate.new(run).generate,
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  def preview!(**params)
    post "#{url}/preview_import", params: params
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def apply(data, **params)
    rows = data.dig("preview", "source_rows").map { |row| { id: row["id"], disposition: row["row_kind"] == "matched" ? "included" : "pending" } }
    post "#{url}/apply_import", params: { import_id: data["import_id"], rows: rows, **params }, as: :json
  end

  def sources(data) = data.dig("source_package", "sources").to_h { |source| [ source["role"], source["present"] ] }

  describe "uploading each file separately" do
    it "previews the PDF alone, then adds the workbook without a reason and applies the complete package" do
      first = preview!(pdf_file: pdf)
      expect(sources(first)).to eq("revel_hours" => true, "supplemental_workbook" => false)
      expect(first.dig("source_package", "complete")).to be(false)

      apply(first)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Add the Tips & loans workbook, or confirm there are no tips or loans this period.")
      expect(run.payroll_items.count).to eq(0)

      second = preview!(excel_file: workbook)
      expect(sources(second)).to eq("revel_hours" => true, "supplemental_workbook" => true)
      expect(second.dig("source_package", "complete")).to be(true)
      expect(second.dig("source_package", "supersession_reason")).to eq("Added: Tips & loans workbook")
      expect(PayrollImportRecord.find(second["import_id"])).to have_attributes(pdf_filename: "payroll_#{run.start_date}_to_#{run.end_date}.pdf", excel_filename: "changes.xlsx")

      apply(first)
      expect(response.parsed_body["error"]).to match(/replaced by a corrected revision/)

      apply(second)
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: employee).hours_worked).to eq(40)
    end

    it "previews the workbook alone and needs the PDF, which cannot be waived" do
      first = preview!(excel_file: workbook)
      expect(sources(first)).to eq("revel_hours" => false, "supplemental_workbook" => true)

      apply(first, no_tips_or_loans: true)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Add the Revel hours PDF before applying.")

      second = preview!(pdf_file: pdf)
      expect(second.dig("source_package", "complete")).to be(true)
      apply(second)
      expect(response).to have_http_status(:ok), response.body
    end

    it "records an explicit no-tips-or-loans choice for a PDF-only package" do
      data = preview!(pdf_file: pdf)
      apply(data, no_tips_or_loans: true)

      expect(response).to have_http_status(:ok), response.body
      waiver = PayrollImportRecord.find(data["import_id"]).raw_data.fetch("source_waivers").sole
      expect(waiver).to include("role" => "supplemental_workbook", "choice" => "No tips or loans this period", "confirmed_by" => "staff", "user_id" => staff.id)
    end

    it "follows the client's own required-files setting" do
      company.update!(payroll_intake_settings: { "mosa_revel" => { "required_sources" => [ "revel_hours" ] } })
      data = preview!(pdf_file: pdf)
      expect(data.dig("source_package", "complete")).to be(true)
      expect(data.dig("source_package", "sources").find { |source| source["role"] == "supplemental_workbook" }).to include("required" => false)

      apply(data)
      expect(response).to have_http_status(:ok), response.body
      expect(PayrollImportRecord.find(data["import_id"]).raw_data.fetch("source_waivers")).to eq([])
    end

    it "asks for a reason to replace a file already in the package" do
      first = preview!(pdf_file: pdf, excel_file: workbook)

      post "#{url}/preview_import", params: { pdf_file: pdf(38) }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "replacement_required")).to be(true)

      second = preview!(pdf_file: pdf(38), supersedes_package_id: first.dig("source_package", "package_id"), supersession_reason: "MoSa corrected Avery's hours")
      expect(sources(second)).to eq("revel_hours" => true, "supplemental_workbook" => true)
      expect(second.dig("preview", "matched").sole).to include("regular_hours" => 38.0)
    end

    it "requires at least one file" do
      post "#{url}/preview_import", params: {}
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Choose the Revel hours PDF, the tips & loans workbook, or both.")
    end
  end

  describe "re-importing over hours changed by hand" do
    it "lists old and new hours and applies only after explicit confirmation" do
      first = preview!(pdf_file: pdf(40), excel_file: workbook)
      apply(first)
      expect(response).to have_http_status(:ok), response.body
      item = run.payroll_items.find_by!(employee: employee)
      expect(item.custom_columns_data["mosa_imported_hours"]).to eq("regular_hours" => "40.0", "overtime_hours" => "2.0")

      # Staff correct the hours in the worksheet after the import.
      item.update!(hours_worked: 36)

      second = preview!(pdf_file: pdf(41), supersedes_package_id: first.dig("source_package", "package_id"), supersession_reason: "MoSa resent Revel")
      expect(second.dig("preview", "matched").sole.fetch("hand_edited_hours")).to include(
        "employee_name" => "Avery Example", "saved_regular_hours" => "36.0", "source_regular_hours" => "41.0",
        "saved_overtime_hours" => "2.0", "source_overtime_hours" => "2.0"
      )

      apply(second)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/replace hours entered by hand for Avery Example/)
      expect(response.parsed_body.dig("details", "hand_edited_hours").sole).to include("employee_id" => employee.id)
      expect(item.reload.hours_worked).to eq(36)

      apply(second, confirm_hours_overwrite: true)
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.hours_worked).to eq(41)
      record = PayrollImportRecord.find(second["import_id"])
      expect(record.raw_data.fetch("replaced_hand_edited_hours").sole).to include("saved_regular_hours" => "36.0", "source_regular_hours" => "41.0")
    end

    it "does not warn when the hours were not changed by hand" do
      first = preview!(pdf_file: pdf(40), excel_file: workbook)
      apply(first)
      second = preview!(pdf_file: pdf(41), supersedes_package_id: first.dig("source_package", "package_id"), supersession_reason: "MoSa resent Revel")

      expect(second.dig("preview", "matched").sole["hand_edited_hours"]).to be_nil
      apply(second)
      expect(response).to have_http_status(:ok), response.body
    end
  end
end
