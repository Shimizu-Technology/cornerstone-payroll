# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127050000_add_import_origin_to_payroll_items_and_imports")

RSpec.describe "Track C B3 import_origin" do
  let(:company) { create(:company, payroll_intake_source_types: %w[mosa_revel spike_email]) }
  let(:pay_period) { create(:pay_period, company: company) }
  let(:employee) { create(:employee, company: company, first_name: "Casey", last_name: "Synthetic", pay_rate: 20) }

  describe "PayrollItem predicates and inference" do
    it "infers import_origin for each import source type and exposes intake_imported? and imported_by?" do
      intake_item = create(:payroll_item, pay_period: pay_period, employee: employee, import_source: "spike_email")
      expect(intake_item.import_origin).to eq("intake")
      expect(intake_item.intake_imported?).to be(true)
      expect(intake_item.imported_by?("spike_email")).to be(true)
      expect(intake_item.imported_by?("mosa_revel")).to be(false)

      second_employee = create(:employee, company: company, first_name: "Morgan", last_name: "Synthetic", pay_rate: 20)
      tt_item = create(:payroll_item, pay_period: pay_period, employee: second_employee, import_source: "time_tracking:42:batch-1")
      expect(tt_item.import_origin).to eq("time_tracking")
      expect(tt_item.intake_imported?).to be(false)

      third_employee = create(:employee, company: company, first_name: "Jordan", last_name: "Synthetic", pay_rate: 20)
      ocr_item = create(:payroll_item, pay_period: pay_period, employee: third_employee, import_source: "timecard_ocr")
      expect(ocr_item.import_origin).to eq("timecard_ocr")
      expect(ocr_item.intake_imported?).to be(false)

      fourth_employee = create(:employee, company: company, first_name: "Taylor", last_name: "Synthetic", pay_rate: 20)
      manual_item = create(:payroll_item, pay_period: pay_period, employee: fourth_employee)
      expect(manual_item.import_origin).to be_nil
      expect(manual_item.intake_imported?).to be(false)
      expect(manual_item.imported_by?("mosa_revel")).to be(false)
    end

    it "rejects unsupported import_origin values at both model and database level" do
      item = build(:payroll_item, pay_period: pay_period, employee: employee, import_origin: "unknown_origin")
      expect(item).not_to be_valid
      expect(item.errors[:import_origin]).to be_present

      persisted = create(:payroll_item, pay_period: pay_period, employee: employee)
      expect {
        persisted.update_column(:import_origin, "unknown_origin")
      }.to raise_error(ActiveRecord::StatementInvalid, /payroll_items_import_origin_check/)
    end

    it "accepts bonus_source 'import' alongside 'manual' and 'mosa_revel'" do
      item = create(:payroll_item, pay_period: pay_period, employee: employee)
      PayrollBonusInput.import!(item, "125.50", source: "import")
      item.save!

      expect(item.reload).to have_attributes(bonus: BigDecimal("125.50"), imported_bonus: BigDecimal("125.50"), bonus_source: "import")
    end
  end

  describe "generalized intake checks without mosa_revel hard-coding" do
    it "treats any intake_imported? item consistently for overwrite, hand-edit, job-sync, and deduction warnings" do
      rate = employee.employee_wage_rates.create!(label: "Barista", rate: 20, is_primary: true, active: true)
      item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        hours_worked: 36,
        overtime_hours: 0,
        import_source: "spike_email",
        import_origin: "intake",
        custom_columns_data: {
          "imported_hours" => { "regular_hours" => "40.0", "overtime_hours" => "0.0" },
          "missing_source_hours" => true,
          "wage_rate_hours" => [
            { "employee_wage_rate_id" => rate.id, "label" => rate.label, "rate" => 20.0,
              "regular_hours" => 36.0, "overtime_hours" => 0.0, "holiday_hours" => 0.0, "pto_hours" => 0.0,
              "is_primary" => true, "active" => true }
          ]
        }
      )

      expect(PayrollImport::ImportService.overwrite_required?(item)).to be(false)

      hand_edit = PayrollImport::LivePreviewRowState.hand_edited_hours(
        { "employee_id" => employee.id, "employee_name" => employee.full_name, "regular_hours" => 41, "overtime_hours" => 0 },
        item
      )
      expect(hand_edit).to include("saved_regular_hours" => "36.0", "source_regular_hours" => "41.0")

      item.update!(hours_worked: 38)
      expect(item.reload.wage_rate_hours.sole.fetch("regular_hours")).to eq(38.0)

      item.update!(hours_worked: 0, overtime_hours: 0)
      expect(item.deduction_review_warnings).to include(include("No Revel hours"))
    end

    it "falls back to legacy mosa_imported_hours and mosa_missing_revel_hours JSON keys" do
      item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        hours_worked: 0,
        overtime_hours: 0,
        import_source: "mosa_revel",
        import_origin: "intake",
        custom_columns_data: {
          "mosa_imported_hours" => { "regular_hours" => "40.0", "overtime_hours" => "0.0" },
          "mosa_missing_revel_hours" => true
        }
      )

      expect(item.imported_hours_snapshot).to eq("regular_hours" => "40.0", "overtime_hours" => "0.0")
      expect(item.missing_source_hours?).to be(true)
      expect(item.deduction_review_warnings).to include(include("No Revel hours"))

      item.update!(hours_worked: 35)
      hand_edit = PayrollImport::LivePreviewRowState.hand_edited_hours(
        { "employee_id" => employee.id, "employee_name" => employee.full_name, "regular_hours" => 40, "overtime_hours" => 0 },
        item
      )
      expect(hand_edit).to include("saved_regular_hours" => "35.0", "source_regular_hours" => "40.0")
    end

    it "marks client submission proposals as not requiring manual overwrite for intake-imported items" do
      owner = create(:employee, company: company, first_name: "Drew", last_name: "Owner",
        employment_type: "salary", salary_type: "variable", pay_rate: 40_000)
      create(:payroll_item, pay_period: pay_period, employee: owner, employment_type: "salary",
        pay_rate: 40_000, salary_override: 1500, import_source: "spike_email", import_origin: "intake")

      submission_period = PayrollSubmissionPeriod.create!(
        company: company, pay_period: pay_period, source: "pay_period",
        start_date: pay_period.start_date, end_date: pay_period.end_date
      )
      submission = submission_period.submissions.create!(
        company: company, revision: 1, submitted_at: Time.current,
        content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32),
        change_rows: [ { "kind" => "owner_pay", "employee_id" => owner.id, "amount" => "1500.00" } ]
      )

      proposals = PayrollSubmissions::ImportChanges.new(submission: submission, pay_period: pay_period).proposals
      expect(proposals.sole.fetch(:overwrite_required)).to be(false)
    end
  end

  describe "PayrollIntake::ImportOrigin provenance builder" do
    it "captures adapter key, descriptor/parser version, portal revision, re-import, and hand-edit replacement" do
      first = create(:payroll_intake_session, company: company, pay_period: pay_period,
        source_type: "mosa_revel", parser_version: "mosa_revel:v1", package_revision: 1, superseded_at: Time.current)
      second = create(:payroll_intake_session, company: company, pay_period: pay_period,
        source_type: "mosa_revel", parser_version: "mosa_revel:v1", package_revision: 2,
        supersedes: first, supersession_reason: "Corrected workbook")

      submission_period = PayrollSubmissionPeriod.create!(
        company: company, pay_period: pay_period, source: "pay_period",
        start_date: pay_period.start_date, end_date: pay_period.end_date
      )
      submission = submission_period.submissions.create!(
        company: company, revision: 3, submitted_at: Time.current,
        content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32)
      )

      origin = PayrollIntake::ImportOrigin.build(
        session: second,
        portal_submission: submission,
        replaced_hand_edited_hours: true
      )

      expect(origin).to include(
        "adapter_key" => "mosa_revel",
        "parser_version" => "mosa_revel:v1",
        "descriptor_version" => "mosa_revel:v1",
        "extraction" => "deterministic",
        "channel" => "portal_revision",
        "package_id" => second.package_id,
        "package_revision" => 2,
        "reimport" => true,
        "supersedes_package_id" => first.package_id,
        "portal_submission_id" => submission.id,
        "portal_revision" => 3,
        "replaced_hand_edited_hours" => true
      )
    end
  end

  describe "migration backfill" do
    it "backfills existing payroll_items and payroll_imports rows safely including committed runs" do
      committed_period = create(:pay_period, company: company, status: "committed",
        start_date: Date.new(2026, 5, 3), end_date: Date.new(2026, 5, 16), pay_date: Date.new(2026, 5, 22))
      e1 = create(:employee, company: company, first_name: "Alpha", last_name: "Backfill")
      e2 = create(:employee, company: company, first_name: "Beta", last_name: "Backfill")
      e3 = create(:employee, company: company, first_name: "Gamma", last_name: "Backfill")
      e4 = create(:employee, company: company, first_name: "Delta", last_name: "Backfill")

      mosa_item = create(:payroll_item, pay_period: committed_period, employee: e1, import_source: "mosa_revel")
      tt_item = create(:payroll_item, pay_period: committed_period, employee: e2, import_source: "time_tracking:9:run-1")
      ocr_item = create(:payroll_item, pay_period: committed_period, employee: e3, import_source: "timecard_ocr")
      manual_item = create(:payroll_item, pay_period: committed_period, employee: e4, import_source: nil)

      PayrollItem.where(id: [ mosa_item.id, tt_item.id, ocr_item.id, manual_item.id ]).update_all(import_origin: nil)

      session = create(:payroll_intake_session, company: company, pay_period: committed_period,
        source_type: "mosa_revel", parser_version: "mosa_revel:v1")
      import_record = PayrollImportRecord.create!(
        pay_period: committed_period,
        payroll_intake_session: session,
        status: "applied",
        raw_data: { "replaced_hand_edited_hours" => [ { "employee_id" => e1.id } ] }
      )
      PayrollImportRecord.where(id: import_record.id).update_all(import_origin: {})

      migration = AddImportOriginToPayrollItemsAndImports.new
      allow(migration).to receive(:say)
      migration.send(:backfill_payroll_items_import_origin!)
      migration.send(:backfill_payroll_imports_import_origin!)

      expect(mosa_item.reload.import_origin).to eq("intake")
      expect(tt_item.reload.import_origin).to eq("time_tracking")
      expect(ocr_item.reload.import_origin).to eq("timecard_ocr")
      expect(manual_item.reload.import_origin).to be_nil

      expect(import_record.reload.import_origin).to include(
        "adapter_key" => "mosa_revel",
        "parser_version" => "mosa_revel:v1",
        "channel" => "staff_upload",
        "reimport" => false,
        "replaced_hand_edited_hours" => true,
        "backfilled" => true
      )
    end
  end

  describe "end-to-end import_origin recording on PayrollImportsController", type: :request do
    let(:staff) { create(:user, company: company, role: "admin") }
    let(:objects) { {} }
    let(:storage) do
      entries = objects
      Object.new.tap do |store|
        store.define_singleton_method(:upload) { |key, data, **| entries[key] = data.respond_to?(:read) ? File.binread(data.path) : data }
        store.define_singleton_method(:download_with_limit) { |key, max_bytes:| entries.fetch(key).byteslice(0, max_bytes) }
        store.define_singleton_method(:delete) { |key| entries.delete(key) }
      end
    end

    before do
      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
      allow(R2StorageService).to receive(:new).and_return(storage)
      allow(ClientDocumentScanner).to receive(:adapter).and_return(ClientDocumentScanner::Noop.new)
      config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: pay_period.pay_date.year)
      create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
      CompanyWorkweek.create!(
        company: company,
        starts_on_weekday: pay_period.start_date.wday,
        starts_at_minutes: 0,
        timezone: "Pacific/Guam",
        effective_on: pay_period.start_date - 7,
        source: "operator_confirmed",
        confirmation_status: "confirmed",
        confirmed_by: staff,
        confirmed_at: Time.current,
        notes: "Synthetic workweek"
      )
    end

    def revel_pdf_for(hours)
      path = build_revel_pdf(
        [ { name: "#{employee.last_name}, #{employee.first_name}", regular_hours: hours, overtime_hours: 0, regular_pay: 500 } ],
        period_start: pay_period.start_date,
        period_end: pay_period.end_date
      )
      portal_upload("revel.pdf", File.binread(path), "application/pdf")
    end

    it "records staff upload, hand-edit re-import, and portal revision import_origin on imports and items" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { pdf_file: revel_pdf_for(40) }
      expect(response).to have_http_status(:ok), response.body
      first_body = response.parsed_body
      first_import = PayrollImportRecord.find(first_body.fetch("import_id"))
      expect(first_import.import_origin).to include(
        "adapter_key" => "mosa_revel",
        "parser_version" => "mosa_revel:v1",
        "descriptor_version" => "mosa_revel:v1",
        "channel" => "staff_upload",
        "reimport" => false,
        "replaced_hand_edited_hours" => false
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: first_import.id, no_tips_or_loans: true }, as: :json
      expect(response).to have_http_status(:ok), response.body
      item = pay_period.payroll_items.find_by!(employee: employee)
      expect(item).to have_attributes(import_source: "mosa_revel", import_origin: "intake")
      expect(item.custom_columns_data.fetch("imported_hours")).to eq("regular_hours" => "40.0", "overtime_hours" => "0.0")

      item.update!(hours_worked: 37)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: {
        pdf_file: revel_pdf_for(42),
        supersedes_package_id: first_body.dig("source_package", "package_id"),
        supersession_reason: "Synthetic re-import over hand edit"
      }
      expect(response).to have_http_status(:ok), response.body
      second_body = response.parsed_body

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: second_body.fetch("import_id"), no_tips_or_loans: true, confirm_hours_overwrite: true }, as: :json
      expect(response).to have_http_status(:ok), response.body
      second_import = PayrollImportRecord.find(second_body.fetch("import_id"))
      expect(second_import.import_origin).to include(
        "adapter_key" => "mosa_revel",
        "parser_version" => "mosa_revel:v1",
        "channel" => "staff_upload",
        "reimport" => true,
        "supersedes_package_id" => first_body.dig("source_package", "package_id"),
        "replaced_hand_edited_hours" => true
      )

      client = create(:user, company: company, role: "client")
      CompanyAssignment.create!(user: client, company: company)
      period_key = "#{pay_period.start_date}_#{pay_period.end_date}"
      catalog = PayrollSubmissions::Catalog.new(company: company, today: pay_period.end_date + 1)
      submission = PayrollSubmissions::CreateRevision.new(
        company: company, actor: client, catalog: catalog, entry: catalog.resolve(period_key),
        params: { revel_payroll: revel_pdf_for(44), workbook_choice: "none", no_changes: true }
      ).call.submission

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: {
        submission_id: submission.id,
        supersedes_package_id: second_body.dig("source_package", "package_id"),
        supersession_reason: "Portal revision replaces staff upload"
      }
      expect(response).to have_http_status(:ok), response.body
      portal_body = response.parsed_body
      portal_import = PayrollImportRecord.find(portal_body.fetch("import_id"))
      expect(portal_import.import_origin).to include(
        "adapter_key" => "mosa_revel",
        "parser_version" => "mosa_revel:v1",
        "channel" => "portal_revision",
        "portal_submission_id" => submission.id,
        "portal_revision" => submission.revision,
        "reimport" => true
      )
    end
  end
end
