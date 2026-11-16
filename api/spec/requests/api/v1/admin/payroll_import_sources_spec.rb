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

  describe "removing a file from an import in review" do
    it "takes out a workbook added by mistake with a reason, so the PDF alone can apply with no tips or loans" do
      preview!(pdf_file: pdf)
      complete = preview!(excel_file: workbook)

      post "#{url}/remove_import_source", params: { source_role: "supplemental_workbook", reason: " " }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Say why the Tips & loans workbook is being removed (up to 500 characters).")

      post "#{url}/remove_import_source", params: { source_role: "supplemental_workbook", reason: "Last period's workbook" }, as: :json
      expect(response).to have_http_status(:ok), response.body
      removed = response.parsed_body
      expect(sources(removed)).to eq("revel_hours" => true, "supplemental_workbook" => false)
      expect(removed.dig("source_package", "supersession_reason")).to eq("Removed: Tips & loans workbook. Last period's workbook")
      expect(removed.dig("source_package", "supersedes_package_id")).to eq(complete.dig("source_package", "package_id"))

      apply(removed, no_tips_or_loans: true)
      expect(response).to have_http_status(:ok), response.body
    end

    it "refuses to remove the only file, a file the import does not have, or a file from an applied import" do
      data = preview!(pdf_file: pdf)
      post "#{url}/remove_import_source", params: { source_role: "revel_hours", reason: "Wrong file" }, as: :json
      expect(response.parsed_body["error"]).to eq("The Revel hours PDF is the only file in this import. Upload the corrected file instead.")
      post "#{url}/remove_import_source", params: { source_role: "supplemental_workbook", reason: "Wrong file" }, as: :json
      expect(response.parsed_body["error"]).to eq("Import version 1 has no Tips & loans workbook to remove.")

      apply(data, no_tips_or_loans: true)
      expect(response).to have_http_status(:ok), response.body
      post "#{url}/remove_import_source", params: { source_role: "revel_hours", reason: "Wrong file" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Only an import still in review can have a file removed.")
    end
  end

  describe "tips in an older MoSa workbook added from the review" do
    before do
      allow(PayrollImport::LoanTipExcelParser).to receive(:parse_file_with_metadata).and_return(
        metadata: { pay_date: run.pay_date, period_end: run.end_date },
        rows: [ { first_name: "Avery", last_name: "Example", total_tips: 25 } ]
      )
    end

    def choose_tips!(data, paid)
      post "#{url}/import_tip_treatment", params: { import_id: data["import_id"], tips_paid_out_from_tips: paid }, as: :json
      expect(response).to have_http_status(:ok), response.body
      response.parsed_body
    end

    it "waits for a recorded choice when the workbook was added from the review, then pays out by it" do
      preview!(pdf_file: pdf)
      # Added from the review: the upload step's tip fallback was not offered.
      added = preview!(excel_file: workbook)
      expect(added.dig("preview", "source_warnings")).to include(include("code" => "legacy_mosa_workbook"))
      expect(added.dig("preview", "tip_treatment_confirmed")).to be(false)

      apply(added)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Choose whether the tips in this older MoSa workbook were already paid out daily.")
      expect(run.payroll_items.count).to eq(0)

      chosen = choose_tips!(added, true)
      expect(chosen.dig("preview", "tips_paid_out_from_tips")).to be(true)
      expect(chosen.dig("preview", "tip_treatment_confirmed")).to be(true)
      # A value sent with apply never overrides the saved choice.
      apply(added, tips_paid_out_from_tips: false)
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: employee)).to have_attributes(reported_tips: 25, tips_paid_out: 25)
      expect(PayrollImportRecord.find(added["import_id"]).raw_data["tip_treatment_confirmed"]).to include("source" => "review", "user_id" => staff.id)
    end

    it "treats uploading with the fallback offered as a choice" do
      data = preview!(pdf_file: pdf, excel_file: workbook, tips_paid_out_from_tips: false)
      expect(data.dig("preview", "tip_treatment_confirmed")).to be(true)
      apply(data)
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: employee)).to have_attributes(reported_tips: 25, tips_paid_out: 0)
    end

    it "keeps a choice when the same workbook is carried into a new version" do
      first = preview!(excel_file: workbook)
      choose_tips!(first, false)

      completed = preview!(pdf_file: pdf)
      expect(completed.dig("preview", "tip_treatment_confirmed")).to be(true)
      expect(completed.dig("preview", "tips_paid_out_from_tips")).to be(false)
      apply(completed)
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: employee)).to have_attributes(reported_tips: 25, tips_paid_out: 0)
    end

    it "refuses the choice for a review without an older workbook" do
      allow(PayrollImport::LoanTipExcelParser).to receive(:parse_file_with_metadata).and_call_original
      data = preview!(pdf_file: pdf, excel_file: workbook)
      post "#{url}/import_tip_treatment", params: { import_id: data["import_id"], tips_paid_out_from_tips: true }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Only an older MoSa workbook needs this choice.")
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
