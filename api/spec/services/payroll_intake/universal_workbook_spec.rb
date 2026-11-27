# frozen_string_literal: true

require "rails_helper"
require "csv"
require "roo"

RSpec.describe "Track C B8-B9: Cornerstone universal workbook, merged apply path, and schedule rules" do
  let(:xlsx_mime) { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }
  let(:csv_mime) { "text/csv" }

  let(:organization) { create(:organization) }
  let(:company) do
    create(
      :company,
      organization: organization,
      name: "Fixture Payroll Client",
      pay_frequency: pay_frequency,
      payroll_intake_source_types: [ "cornerstone_workbook" ]
    )
  end
  let(:pay_frequency) { "biweekly" }
  let(:staff) { create(:user, organization: organization, company: company, role: "admin") }
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      effective_on: Date.new(2026, 1, 1),
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: staff,
      confirmed_at: Time.current,
      notes: "Confirmed Sunday workweek for Track C B8-B9 specs"
    )
  end
  let(:period_start) { Date.new(2026, 6, 14) }
  let(:period_end) { Date.new(2026, 6, 27) }
  let(:pay_date) { Date.new(2026, 7, 3) }
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      company_workweek: workweek,
      start_date: period_start,
      end_date: period_end,
      pay_date: pay_date,
      status: "draft"
    )
  end
  let!(:employee_01) { create(:employee, company: company, first_name: "Employee", last_name: "01", pay_rate: 20.00) }
  let!(:employee_02) { create(:employee, company: company, first_name: "Employee", last_name: "02", pay_rate: 25.00) }
  let!(:inactive_employee) do
    create(:employee, company: company, first_name: "Employee", last_name: "03", status: "terminated", termination_date: Date.new(2026, 5, 1), pay_rate: 18.00)
  end
  let!(:tax_config) do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: 2026)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    config
  end

  let(:stored_objects) { {} }
  let(:storage) do
    entries = stored_objects
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| entries[key] = data.respond_to?(:read) ? File.binread(data.path) : data }
      store.define_singleton_method(:download_with_limit) { |key, max_bytes:| entries.fetch(key).byteslice(0, max_bytes) }
      store.define_singleton_method(:delete) { |key| entries.delete(key) }
    end
  end

  before do
    allow(R2StorageService).to receive(:new).and_return(storage)
  end

  def upload_for(filename, bytes, content_type)
    tempfile = Tempfile.new([ "b8-upload", File.extname(filename) ])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    @tempfiles ||= []
    @tempfiles << tempfile
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: filename, type: content_type)
  end

  after do
    Array(@tempfiles).each(&:close!)
  end

  def build_xlsx_bytes(rows:, company_override: company, period_override: pay_period, schema_version: PayrollIntake::UniversalWorkbook::Template::SCHEMA_VERSION)
    package = Axlsx::Package.new
    workbook = package.workbook
    workbook.add_worksheet(name: PayrollIntake::UniversalWorkbook::Template::START_SHEET) do |sheet|
      sheet.add_row([ "Cornerstone universal payroll workbook" ])
      sheet.add_row([ "Schema version", schema_version ])
      sheet.add_row([ "Company ID", company_override.id ])
      sheet.add_row([ "Company", company_override.name ])
      sheet.add_row([ "Pay period start", period_override.start_date ])
      sheet.add_row([ "Pay period end", period_override.end_date ])
      sheet.add_row([ "Pay date", period_override.pay_date ])
    end
    workbook.add_worksheet(name: PayrollIntake::UniversalWorkbook::Template::PAYROLL_SHEET) do |sheet|
      sheet.add_row(PayrollIntake::UniversalWorkbook::Template::COLUMNS)
      rows.each { |row| sheet.add_row(row) }
    end
    package.to_stream.read
  end

  def build_csv_bytes(rows:, headers: PayrollIntake::UniversalWorkbook::Template::COLUMNS)
    CSV.generate do |csv|
      csv << headers
      rows.each { |row| csv << row }
    end
  end

  describe "Descriptor registration" do
    it "registers cornerstone_workbook with Employee ID matching, portal slot, and template formats" do
      descriptor = PayrollIntake::Registry.fetch("cornerstone_workbook")
      expect(descriptor).to have_attributes(
        key: "cornerstone_workbook",
        label: "Cornerstone workbook",
        parser_version: "cornerstone_workbook:v1",
        extraction: "deterministic",
        employee_match: "employee_id",
        tips_default: "paid_in_check",
        overtime_mode: "weekly_split",
        workweek_alignment: "aligned"
      )
      expect(descriptor.accepts_pasted_text?).to be(false)
      expect(descriptor.portal_submittable?).to be(true)
      expect(descriptor.portal_role_map).to eq("payroll_workbook" => "cornerstone_workbook")
      expect(descriptor.default_required_source_roles).to eq([ "cornerstone_workbook" ])

      slot = descriptor.file_slot("cornerstone_workbook")
      expect(slot.accept).to eq(%w[.xlsx .csv])
      expect(slot.template_formats).to eq(%w[xlsx csv])
      expect(slot.provides).to include("pto_hours", "holiday_hours", "bonus", "one_time_earnings", "loan_deduction")
    end
  end

  describe "Template generation (XLSX and CSV parity)" do
    it "generates per-pay-period XLSX and CSV with identical columns and pre-filled active Employee IDs" do
      generator = PayrollIntake::UniversalWorkbook::Template.new(pay_period: pay_period)
      xlsx_bytes = generator.generate_xlsx
      csv_text = generator.generate_csv

      tempfile = Tempfile.new([ "template", ".xlsx" ])
      tempfile.binmode
      tempfile.write(xlsx_bytes)
      tempfile.close
      (@tempfiles ||= []) << tempfile

      xlsx = Roo::Spreadsheet.open(tempfile.path, extension: :xlsx)
      expect(xlsx.sheets).to eq([ "START HERE", "PAYROLL" ])

      start_sheet = xlsx.sheet("START HERE")
      metadata = (1..start_sheet.last_row).each_with_object({}) do |row_num, acc|
        label = start_sheet.cell(row_num, 1).to_s.strip
        acc[label] = start_sheet.cell(row_num, 2) if label.present?
      end
      expect(metadata.fetch("Schema version")).to eq("cornerstone-universal-workbook/v1")
      expect(metadata.fetch("Company ID").to_i).to eq(company.id)
      expect(metadata.fetch("Pay period start").to_date).to eq(period_start)
      expect(metadata.fetch("Pay period end").to_date).to eq(period_end)
      expect(metadata.fetch("Pay date").to_date).to eq(pay_date)

      payroll_sheet = xlsx.sheet("PAYROLL")
      xlsx_headers = (1..payroll_sheet.last_column).map { |col| payroll_sheet.cell(1, col) }
      csv_rows = CSV.parse(csv_text)
      csv_headers = csv_rows.first

      expect(xlsx_headers).to eq(PayrollIntake::UniversalWorkbook::Template::COLUMNS)
      expect(csv_headers).to eq(xlsx_headers)
      expect(xlsx_headers).to include(
        "Employee ID", "Employee", "Week 1 Hours", "Week 2 Hours",
        "Regular Hours", "Overtime Hours", "PTO Hours", "Holiday Hours",
        "Tips", "Tips Already Paid (YES/NO)", "Bonus",
        "One-Time Item Type", "One-Time Item Label", "One-Time Item Amount",
        "Loan Deduction", "Notes"
      )

      xlsx_employee_ids = (2..payroll_sheet.last_row).map { |row_num| payroll_sheet.cell(row_num, 1).to_i }
      xlsx_employee_names = (2..payroll_sheet.last_row).map { |row_num| payroll_sheet.cell(row_num, 2).to_s }
      csv_employee_ids = csv_rows.drop(1).map { |row| row[0].to_i }
      csv_employee_names = csv_rows.drop(1).map { |row| row[1].to_s }

      expect(xlsx_employee_ids).to eq([ employee_01.id, employee_02.id ])
      expect(csv_employee_ids).to eq([ employee_01.id, employee_02.id ])
      expect(xlsx_employee_ids).not_to include(inactive_employee.id)
      expect(csv_employee_ids).not_to include(inactive_employee.id)
      expect(xlsx_employee_names).to eq([ "Employee 01", "Employee 02" ])
      expect(csv_employee_names).to eq([ "Employee 01", "Employee 02" ])
    end
  end

  describe "Strict parsing edge cases with BigDecimal numeric assertions" do
    it "parses identical numeric BigDecimal rows from XLSX and CSV" do
      data_rows = [
        [ employee_01.id, "Employee 01", "42.25", "37.75", "", "", "4.50", "8.00", "$125.40", "YES", "$250.00", "REIMBURSEMENT", "Uniform", "$34.99", "$45.25", "Clean row" ],
        [ employee_02.id, "Employee 02", "", "", "", "", "", "", "", "", "", "", "", "", "", "" ] # blank input row skipped
      ]

      xlsx_parsed = PayrollIntake::UniversalWorkbook::Parser.parse_file(
        upload_for("payroll.xlsx", build_xlsx_bytes(rows: data_rows), xlsx_mime),
        company: company,
        pay_period: pay_period
      )
      csv_parsed = PayrollIntake::UniversalWorkbook::Parser.parse_file(
        upload_for("payroll.csv", build_csv_bytes(rows: data_rows), csv_mime),
        company: company,
        pay_period: pay_period
      )

      expect(xlsx_parsed[:rows].length).to eq(1)
      expect(csv_parsed[:rows].length).to eq(1)

      [ xlsx_parsed[:rows].sole, csv_parsed[:rows].sole ].each do |row|
        expect(row[:parse_errors]).to be_empty
        expect(row[:employee_id]).to eq(employee_01.id)
        expect(row[:week1_hours]).to eq(BigDecimal("42.25"))
        expect(row[:week2_hours]).to eq(BigDecimal("37.75"))
        expect(row[:pto_hours]).to eq(BigDecimal("4.50"))
        expect(row[:holiday_hours]).to eq(BigDecimal("8.00"))
        expect(row[:tips]).to eq(BigDecimal("125.40"))
        expect(row[:tips_already_paid]).to be(true)
        expect(row[:bonus]).to eq(BigDecimal("250.00"))
        expect(row[:loan_deduction]).to eq(BigDecimal("45.25"))
        expect(row[:payroll_components].sole).to include(
          component_type: "REIMBURSEMENT",
          label: "Uniform",
          amount: BigDecimal("34.99"),
          kind: "addition",
          tax_treatment: "non_taxable_addition"
        )
      end
    end

    it "rejects negative hours, malformed numbers, truthy-string booleans, and invalid one-time items as row-level errors without crashing" do
      bad_rows = [
        [ employee_01.id, "Employee 01", "-5.00", "40", "", "", "forty", "-2", "abc", "maybe", "-10", "UNKNOWN_TYPE", "Bad", "0", "-5", "" ],
        [ employee_02.id, "Employee 02", "40", "40", "", "", "", "", "10", "true", "", "", "", "", "", "" ]
      ]
      csv_file = upload_for("edge-cases.csv", build_csv_bytes(rows: bad_rows), csv_mime)
      parsed = PayrollIntake::UniversalWorkbook::Parser.parse_file(csv_file, company: company, pay_period: pay_period)

      row1 = parsed[:rows][0]
      codes1 = row1[:parse_errors].map { |err| err.fetch(:code) }
      expect(codes1).to include(
        "negative_hours",
        "invalid_pto_hours",
        "invalid_tips",
        "invalid_tips_already_paid",
        "negative_amount",
        "invalid_one_time_item_type",
        "invalid_one_time_item_amount"
      )

      row2 = parsed[:rows][1]
      expect(row2[:parse_errors].map { |err| err.fetch(:code) }).to eq([ "invalid_tips_already_paid" ])
    end

    it "matches strictly by Employee ID and never falls back to employee name" do
      # Row 1: exact active employee name, but wrong Employee ID -> MUST NOT match employee_01!
      # Row 2: inactive employee ID -> MUST NOT match!
      # Row 3: valid Employee ID with edited/mismatched name -> MUST match employee_02 by ID!
      rows = [
        [ 999_999, "Employee 01", "40", "40", "", "", "", "", "", "", "", "", "", "", "", "" ],
        [ inactive_employee.id, "Employee 03", "40", "40", "", "", "", "", "", "", "", "", "", "", "", "" ],
        [ employee_02.id, "Renamed In Sheet", "38.50", "40.00", "", "", "", "", "", "", "", "", "", "", "", "" ]
      ]
      file = upload_for("id-match.csv", build_csv_bytes(rows: rows), csv_mime)
      preview = PayrollIntake::PreviewService.new(
        pay_period: pay_period,
        source_type: "cornerstone_workbook",
        files: [ file ],
        actor: staff
      ).call
      session = preview.fetch(:session)

      row_unknown, row_inactive, row_matched = session.rows.in_order.to_a
      expect(row_unknown.employee_id).to be_nil
      expect(row_unknown.errors_payload.map { |e| e["code"] }).to include("unmatched_employee_id")

      expect(row_inactive.employee_id).to be_nil
      expect(row_inactive.errors_payload.map { |e| e["code"] }).to include("inactive_employee_id")
      expect(row_inactive.errors_payload.first["message"]).to include("terminated")

      expect(row_matched.employee_id).to eq(employee_02.id)
      expect(row_matched.match_method).to eq("employee_id")
      expect(row_matched.errors_payload).to be_empty
    end

    it "rejects an XLSX belonging to a different client or pay period" do
      other_company = create(:company, organization: organization)
      wrong_company_xlsx = upload_for("wrong-company.xlsx", build_xlsx_bytes(rows: [], company_override: other_company), xlsx_mime)
      expect {
        PayrollIntake::UniversalWorkbook::Parser.parse_file(wrong_company_xlsx, company: company, pay_period: pay_period)
      }.to raise_error(ArgumentError, /belongs to another client/)

      wrong_period = build(:pay_period, company: company, start_date: period_start - 14, end_date: period_end - 14, pay_date: pay_date - 14)
      wrong_period_xlsx = upload_for("wrong-period.xlsx", build_xlsx_bytes(rows: [], period_override: wrong_period), xlsx_mime)
      expect {
        PayrollIntake::UniversalWorkbook::Parser.parse_file(wrong_period_xlsx, company: company, pay_period: pay_period)
      }.to raise_error(ArgumentError, /start date/)
    end
  end

  describe "Preview -> Apply through the merged PayrollIntake::ApplyService path" do
    it "applies hours, PTO, holiday, tips (with per-row override), bonus, one-time item, and loan deduction end-to-end" do
      rows = [
        [ employee_01.id, "Employee 01", "45.00", "35.00", "", "", "8.00", "4.00", "150.25", "YES", "300.00", "REIMBURSEMENT", "Parking Pass", "25.50", "50.00", "Biweekly sample" ],
        [ employee_02.id, "Employee 02", "40.00", "40.00", "", "", "0", "0", "80.00", "", "", "", "", "", "0", "Default tips paid in check" ]
      ]
      xlsx_file = upload_for("biweekly.xlsx", build_xlsx_bytes(rows: rows), xlsx_mime)

      preview_result = PayrollIntake::PreviewService.new(
        pay_period: pay_period,
        source_type: "cornerstone_workbook",
        files: [ xlsx_file ],
        actor: staff
      ).call
      session = preview_result.fetch(:session)
      expect(session.status).to eq("previewed")
      expect(session.documents.sole.source_role).to eq("cornerstone_workbook")

      row_overrides = session.rows.in_order.map { |row| { id: row.id, disposition: "included" } }
      apply_result = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: row_overrides,
        actor: staff
      ).call

      expect(apply_result[:errors]).to be_empty
      expect(apply_result[:applied].length).to eq(2)
      expect(session.reload.status).to eq("applied")
      expect(pay_period.reload.status).to eq("calculated")

      item_01 = pay_period.payroll_items.find_by!(employee: employee_01)
      # Biweekly 29 CFR 778.104: Week 1 = 45 (40 reg + 5 OT), Week 2 = 35 (35 reg + 0 OT) => 75 reg + 5 OT!
      expect(item_01.hours_worked).to eq(BigDecimal("75.00"))
      expect(item_01.overtime_hours).to eq(BigDecimal("5.00"))
      expect(item_01.pto_hours).to eq(BigDecimal("8.00"))
      expect(item_01.holiday_hours).to eq(BigDecimal("4.00"))
      expect(item_01.reported_tips).to eq(BigDecimal("150.25"))
      expect(item_01.tips_paid_out).to eq(BigDecimal("150.25"))
      expect(item_01.bonus).to eq(BigDecimal("300.00"))
      expect(item_01.bonus_source).to eq("import")
      expect(item_01.loan_deduction).to eq(BigDecimal("50.00"))
      expect(item_01.import_source).to eq("cornerstone_workbook")
      expect(item_01.import_origin).to eq("intake")

      # Exact gross check: (75 + 8 + 4)*$20 + 5*$30 + $150.25 tips + $300 bonus = $1740 + $150 + $150.25 + $300 = $2340.25
      expect(item_01.gross_pay).to eq(BigDecimal("2340.25"))
      reimbursement = item_01.payroll_item_field_entries.find_by!(label: "Parking Pass")
      expect(reimbursement).to have_attributes(
        amount: BigDecimal("25.50"),
        kind: "addition",
        tax_treatment: "non_taxable_addition",
        source: "import"
      )

      item_02 = pay_period.payroll_items.find_by!(employee: employee_02)
      expect(item_02.hours_worked).to eq(BigDecimal("80.00"))
      expect(item_02.overtime_hours).to eq(BigDecimal("0.00"))
      expect(item_02.reported_tips).to eq(BigDecimal("80.00"))
      expect(item_02.tips_paid_out).to eq(BigDecimal("0.00"))
    end
  end

  describe "Schedule rules (29 CFR 778.104) with numeric overtime examples" do
    context "weekly schedule (7-day legal workweek)" do
      let(:pay_frequency) { "weekly" }
      let(:period_start) { Date.new(2026, 6, 14) }
      let(:period_end) { Date.new(2026, 6, 20) }
      let(:pay_date) { Date.new(2026, 6, 26) }

      it "calculates overtime over 40h in the single 7-day workweek and rejects nonzero Week 2 hours" do
        csv_file = upload_for("weekly.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "46.50", "", "", "", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        session = PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "cornerstone_workbook",
          files: [ csv_file ],
          actor: staff
        ).call.fetch(:session)

        result = PayrollIntake::ApplyService.new(
          session: session,
          row_overrides: [ { id: session.rows.sole.id, disposition: "included" } ],
          actor: staff
        ).call

        expect(result[:errors]).to be_empty
        item = pay_period.payroll_items.find_by!(employee: employee_01)
        expect(item.hours_worked).to eq(BigDecimal("40.00"))
        expect(item.overtime_hours).to eq(BigDecimal("6.50"))
        # 40 * $20 + 6.50 * $30 = $800 + $195 = $995.00
        expect(item.gross_pay).to eq(BigDecimal("995.00"))

        bad_csv = upload_for("weekly-bad.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "40.00", "5.00", "", "", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)
        bad_session = PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "cornerstone_workbook",
          files: [ bad_csv ],
          actor: staff,
          supersedes_package_id: session.package_id,
          supersession_reason: "Testing weekly Week 2 rejection"
        ).call.fetch(:session)
        expect(bad_session.rows.sole.errors_payload.map { |e| e["code"] }).to include("week2_not_allowed_on_weekly")
      end
    end

    context "biweekly schedule (two independent 7-day legal workweeks)" do
      let(:pay_frequency) { "biweekly" }

      it "calculates overtime per 7-day workweek without averaging (45h + 35h = 75 reg + 5 OT, not 80 reg)" do
        csv_file = upload_for("biweekly-ot.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "45.00", "35.00", "", "", "", "", "", "", "", "", "", "", "", "" ],
          [ employee_02.id, "Employee 02", "42.25", "44.50", "", "", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        session = PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "cornerstone_workbook",
          files: [ csv_file ],
          actor: staff
        ).call.fetch(:session)

        result = PayrollIntake::ApplyService.new(
          session: session,
          row_overrides: session.rows.in_order.map { |r| { id: r.id, disposition: "included" } },
          actor: staff
        ).call

        expect(result[:errors]).to be_empty
        item_01 = pay_period.payroll_items.find_by!(employee: employee_01)
        expect(item_01.hours_worked).to eq(BigDecimal("75.00"))
        expect(item_01.overtime_hours).to eq(BigDecimal("5.00"))
        # 75 * $20 + 5 * $30 = $1500 + $150 = $1650.00
        expect(item_01.gross_pay).to eq(BigDecimal("1650.00"))

        item_02 = pay_period.payroll_items.find_by!(employee: employee_02)
        expect(item_02.hours_worked).to eq(BigDecimal("80.00"))
        expect(item_02.overtime_hours).to eq(BigDecimal("6.75"))
        # 80 * $25 + 6.75 * $37.50 = $2000 + $253.125 -> $2253.13
        expect(item_02.gross_pay).to eq(BigDecimal("2253.13"))
      end
    end

    context "semimonthly schedule (source reports overtime only per 29 CFR 778.104)" do
      let(:pay_frequency) { "semimonthly" }
      let(:period_start) { Date.new(2026, 6, 16) }
      let(:period_end) { Date.new(2026, 6, 30) }
      let(:pay_date) { Date.new(2026, 7, 15) }

      it "rejects Payroll-calculated overtime on semimonthly periods and accepts source-reported overtime with numeric fidelity" do
        csv_file = upload_for("semimonthly.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "", "", "80.00", "7.50", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        # Default cornerstone_workbook overtime_mode is weekly_split -> MUST be rejected per 29 CFR 778.104
        expect {
          PayrollIntake::PreviewService.new(
            pay_period: pay_period,
            source_type: "cornerstone_workbook",
            files: [ csv_file ],
            actor: staff
          ).call
        }.to raise_error(ArgumentError, /29 CFR 778\.104/)

        # Switch company setting to source_reports -> semimonthly succeeds cleanly!
        company.update!(payroll_intake_settings: {
          "cornerstone_workbook" => { "overtime_mode" => "source_reports" }
        })

        csv_file2 = upload_for("semimonthly-sr.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "", "", "80.00", "7.50", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        session = PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "cornerstone_workbook",
          files: [ csv_file2 ],
          actor: staff
        ).call.fetch(:session)

        expect(session.warnings.map { |w| w["code"] }).to include("pay_period_workweek_offset")

        result = PayrollIntake::ApplyService.new(
          session: session,
          row_overrides: [ { id: session.rows.sole.id, disposition: "included" } ],
          actor: staff
        ).call

        expect(result[:errors]).to be_empty
        item = pay_period.payroll_items.find_by!(employee: employee_01)
        expect(item.hours_worked).to eq(BigDecimal("80.00"))
        expect(item.overtime_hours).to eq(BigDecimal("7.50"))
        # 80 * $20 + 7.50 * $30 = $1600 + $225 = $1825.00
        expect(item.gross_pay).to eq(BigDecimal("1825.00"))
      end
    end

    context "monthly schedule (source reports overtime only per 29 CFR 778.104)" do
      let(:pay_frequency) { "monthly" }
      let(:period_start) { Date.new(2026, 6, 1) }
      let(:period_end) { Date.new(2026, 6, 30) }
      let(:pay_date) { Date.new(2026, 7, 5) }

      it "rejects computed overtime on monthly periods and accepts source-reported overtime" do
        csv_file = upload_for("monthly.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "", "", "160.00", "12.25", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        expect {
          PayrollIntake::PreviewService.new(
            pay_period: pay_period,
            source_type: "cornerstone_workbook",
            files: [ csv_file ],
            actor: staff
          ).call
        }.to raise_error(ArgumentError, /29 CFR 778\.104/)

        company.update!(payroll_intake_settings: {
          "cornerstone_workbook" => { "overtime_mode" => "source_reports" }
        })

        csv_file2 = upload_for("monthly-sr.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "", "", "160.00", "12.25", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        session = PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "cornerstone_workbook",
          files: [ csv_file2 ],
          actor: staff
        ).call.fetch(:session)

        result = PayrollIntake::ApplyService.new(
          session: session,
          row_overrides: [ { id: session.rows.sole.id, disposition: "included" } ],
          actor: staff
        ).call

        expect(result[:errors]).to be_empty
        item = pay_period.payroll_items.find_by!(employee: employee_01)
        expect(item.hours_worked).to eq(BigDecimal("160.00"))
        expect(item.overtime_hours).to eq(BigDecimal("12.25"))
      end

      it "rejects conflicting mixed weekly and regular/OT hours in source_reports mode unless they reconcile" do
        company.update!(payroll_intake_settings: {
          "cornerstone_workbook" => { "overtime_mode" => "source_reports" }
        })

        conflicting_csv = upload_for("monthly-conflict.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "45.00", "35.00", "40.00", "", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        session = PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "cornerstone_workbook",
          files: [ conflicting_csv ],
          actor: staff
        ).call.fetch(:session)

        row = session.rows.sole
        expect(row.errors_payload.map { |e| e["code"] }).to include("conflicting_hours_columns")
        expect(row.errors_payload.first["message"]).to include("80.00").and include("40.00")

        apply_result = PayrollIntake::ApplyService.new(
          session: session,
          row_overrides: [ { id: row.id, disposition: "included" } ],
          actor: staff
        ).call
        expect(apply_result[:errors]).not_to be_empty
        expect(pay_period.payroll_items.where(employee: employee_01)).to be_empty

        # Reconciled mixed input (45 + 35 == 75 + 5 == 80) succeeds cleanly
        reconciled_csv = upload_for("monthly-reconciled.csv", build_csv_bytes(rows: [
          [ employee_01.id, "Employee 01", "45.00", "35.00", "75.00", "5.00", "", "", "", "", "", "", "", "", "", "" ]
        ]), csv_mime)

        session2 = PayrollIntake::PreviewService.new(
          pay_period: pay_period,
          source_type: "cornerstone_workbook",
          files: [ reconciled_csv ],
          actor: staff,
          supersedes_package_id: session.package_id,
          supersession_reason: "Reconciled hours"
        ).call.fetch(:session)

        expect(session2.rows.sole.errors_payload).to be_empty
        apply_result2 = PayrollIntake::ApplyService.new(
          session: session2,
          row_overrides: [ { id: session2.rows.sole.id, disposition: "included" } ],
          actor: staff
        ).call
        expect(apply_result2[:errors]).to be_empty
        item = pay_period.payroll_items.find_by!(employee: employee_01)
        expect(item.hours_worked).to eq(BigDecimal("75.00"))
        expect(item.overtime_hours).to eq(BigDecimal("5.00"))
      end
    end
  end

  describe "Contractor field policy (1099 rows)" do
    let!(:hourly_contractor) do
      create(
        :employee,
        company: company,
        first_name: "Contractor",
        last_name: "01",
        employment_type: "contractor",
        contractor_type: "individual",
        contractor_pay_type: "hourly",
        pay_rate: 20.00
      )
    end
    let!(:flat_fee_contractor) do
      create(
        :employee,
        company: company,
        first_name: "Contractor",
        last_name: "02",
        employment_type: "contractor",
        contractor_type: "individual",
        contractor_pay_type: "flat_fee",
        pay_rate: 1500.00
      )
    end

    it "rejects PTO, holiday, and tips (including tips already paid) on contractor rows instead of silently dropping or offsetting them" do
      csv_file = upload_for("contractor-unsupported.csv", build_csv_bytes(rows: [
        [ hourly_contractor.id, "Contractor 01", "40.00", "0", "", "", "4.00", "8.00", "60.00", "YES", "", "", "", "", "", "" ],
        [ flat_fee_contractor.id, "Contractor 02", "40.00", "0", "", "", "", "", "", "", "", "", "", "", "", "" ]
      ]), csv_mime)

      session = PayrollIntake::PreviewService.new(
        pay_period: pay_period,
        source_type: "cornerstone_workbook",
        files: [ csv_file ],
        actor: staff
      ).call.fetch(:session)

      hourly_row = session.rows.find_by!(employee_id: hourly_contractor.id)
      expect(hourly_row.errors_payload.map { |e| e["code"] }).to contain_exactly(
        "contractor_unsupported_pto_hours",
        "contractor_unsupported_holiday_hours",
        "contractor_unsupported_tips"
      )

      flat_row = session.rows.find_by!(employee_id: flat_fee_contractor.id)
      expect(flat_row.errors_payload.map { |e| e["code"] }).to contain_exactly("contractor_unsupported_hours")

      result = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [
          { id: hourly_row.id, disposition: "included" },
          { id: flat_row.id, disposition: "excluded", disposition_reason: "Flat-fee handled separately" }
        ],
        actor: staff
      ).call
      expect(result[:errors]).not_to be_empty
      expect(pay_period.payroll_items.where(employee: hourly_contractor)).to be_empty
    end

    it "applies supported contractor fields (hourly hours + bonus) accurately with zero tax or tip offset" do
      csv_file = upload_for("contractor-clean.csv", build_csv_bytes(rows: [
        [ hourly_contractor.id, "Contractor 01", "40.00", "0", "", "", "", "", "", "", "50.00", "", "", "", "", "" ]
      ]), csv_mime)

      session = PayrollIntake::PreviewService.new(
        pay_period: pay_period,
        source_type: "cornerstone_workbook",
        files: [ csv_file ],
        actor: staff
      ).call.fetch(:session)

      expect(session.rows.sole.errors_payload).to be_empty
      result = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [ { id: session.rows.sole.id, disposition: "included" } ],
        actor: staff
      ).call
      expect(result[:errors]).to be_empty

      item = pay_period.payroll_items.find_by!(employee: hourly_contractor)
      # 40 hrs * $20 + $50 bonus = $850 gross, $0 deductions, $850 net
      expect(item.gross_pay).to eq(BigDecimal("850.00"))
      expect(item.total_deductions).to eq(BigDecimal("0.00"))
      expect(item.net_pay).to eq(BigDecimal("850.00"))
    end
  end

  describe "XLSX formula rejection, Float-free BigDecimal reading, and precision bounds" do
    def inject_xlsx_formulas(base_bytes, cached_formula: true)
      source_tmp = Tempfile.new([ "formula-src", ".xlsx" ])
      source_tmp.binmode
      source_tmp.write(base_bytes)
      source_tmp.close
      (@tempfiles ||= []) << source_tmp

      out_tmp = Tempfile.new([ "formula-out", ".xlsx" ])
      out_tmp.binmode
      Zip::OutputStream.open(out_tmp.path) do |out|
        Zip::File.open(source_tmp.path) do |zip|
          zip.each do |entry|
            content = entry.get_input_stream.read
            if entry.name == "xl/worksheets/sheet2.xml"
              replacement = cached_formula ? "<f>SUM(40,5)</f><v>45</v>" : "<f>SUM(40,5)</f>"
              content = content.sub(%r{<v>40\.00</v>|<v>40</v>}, replacement)
            end
            out.put_next_entry(entry.name)
            out.write(content)
          end
        end
      end
      (@tempfiles ||= []) << out_tmp
      File.binread(out_tmp.path)
    end

    it "rejects both cached and uncached XLSX formula cells and CSV formulas with formula_not_allowed" do
      base_xlsx = build_xlsx_bytes(rows: [
        [ employee_01.id, "Employee 01", 40, 35, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil ]
      ])

      [ true, false ].each do |cached|
        formula_xlsx = inject_xlsx_formulas(base_xlsx, cached_formula: cached)
        parsed = PayrollIntake::UniversalWorkbook::Parser.parse_file(
          upload_for("formula-#{cached}.xlsx", formula_xlsx, xlsx_mime),
          company: company,
          pay_period: pay_period
        )
        codes = parsed.fetch(:rows).sole.fetch(:parse_errors).map { |e| e[:code] }
        expect(codes).to include("formula_not_allowed")
      end

      csv_formula = build_csv_bytes(rows: [
        [ employee_01.id, "Employee 01", "=40+5", "35", "", "", "", "", "", "", "", "", "", "", "", "" ]
      ])
      parsed_csv = PayrollIntake::UniversalWorkbook::Parser.parse_file(
        upload_for("formula.csv", csv_formula, csv_mime),
        company: company,
        pay_period: pay_period
      )
      expect(parsed_csv.fetch(:rows).sole.fetch(:parse_errors).map { |e| e[:code] }).to include("formula_not_allowed")
    end

    it "reads XLSX numeric cells directly from raw XML into BigDecimal without Float rounding and enforces precision bounds" do
      xlsx_bytes = build_xlsx_bytes(rows: [
        [ employee_01.id, "Employee 01", 40.15, 39.85, nil, nil, nil, nil, 99_999_999.99, "NO", nil, nil, nil, nil, nil, nil ],
        [ employee_02.id, "Employee 02", 1_000_000.00, 0, nil, nil, nil, nil, 100_000_000.00, "NO", nil, nil, nil, nil, nil, nil ]
      ])

      parsed = PayrollIntake::UniversalWorkbook::Parser.parse_file(
        upload_for("precision.xlsx", xlsx_bytes, xlsx_mime),
        company: company,
        pay_period: pay_period
      )
      row1, row2 = parsed.fetch(:rows)

      expect(row1[:parse_errors]).to be_empty
      expect(row1[:week1_hours]).to eq(BigDecimal("40.15"))
      expect(row1[:week2_hours]).to eq(BigDecimal("39.85"))
      expect(row1[:tips]).to eq(BigDecimal("99999999.99"))

      error_codes = row2[:parse_errors].map { |e| e[:code] }
      expect(error_codes).to eq(%w[value_out_of_range value_out_of_range])
    end
  end

  describe "Migration 20261127220000 rollback safety" do
    it "refuses rollback with IrreversibleMigration before mutating schema when cornerstone_workbook documents exist" do
      require Rails.root.join("db/migrate/20261127220000_widen_payroll_intake_document_roles_for_universal_workbook.rb")

      csv_file = upload_for("migration-guard.csv", build_csv_bytes(rows: [
        [ employee_01.id, "Employee 01", "40.00", "40.00", "", "", "", "", "", "", "", "", "", "", "", "" ]
      ]), csv_mime)

      PayrollIntake::PreviewService.new(
        pay_period: pay_period,
        source_type: "cornerstone_workbook",
        files: [ csv_file ],
        actor: staff
      ).call

      migration = WidenPayrollIntakeDocumentRolesForUniversalWorkbook.new
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /cornerstone_workbook/)
      expect(
        ActiveRecord::Base.connection.index_exists?(
          :payroll_submission_documents,
          :payroll_submission_id,
          name: WidenPayrollIntakeDocumentRolesForUniversalWorkbook::WORKBOOK_INDEX_NAME
        )
      ).to be(true)
    end
  end
end
