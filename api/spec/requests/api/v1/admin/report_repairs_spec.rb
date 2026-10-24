# frozen_string_literal: true

require "rails_helper"
require "csv"
require "pdf/reader"
require "roo"

RSpec.describe "Payroll reporting QA repairs", type: :request do
  let(:company) { create(:company, name: "Synthetic Reporting QA") }
  let(:employee) { create(:employee, company: company, first_name: "Casey", last_name: "Fixture") }
  let(:user) { create(:user, :admin, company: company) }
  let(:period) do
    create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 9, 16), end_date: Date.new(2026, 9, 30), pay_date: Date.new(2026, 10, 15))
  end
  let!(:item) do
    create(:payroll_item, company: company, employee: employee, pay_period: period,
      hours_worked: 76, overtime_hours: 5, gross_pay: 3996.67, net_pay: 3483.83,
      withholding_tax: 197.09, additional_withholding: 10,
      social_security_tax: 247.79, employer_social_security_tax: 247.79,
      medicare_tax: 57.96, employer_medicare_tax: 57.96,
      total_deductions: 512.84)
  end

  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(user)
  end

  def pdf_reader
    expect(response).to have_http_status(:ok), response.body.first(500)
    PDF::Reader.new(StringIO.new(response.body))
  end

  def pdf_text
    pdf_reader.pages.map(&:text).join(" ").gsub(/\s+/, " ")
  end

  def with_workbook
    expect(response).to have_http_status(:ok)
    Tempfile.create([ "report-repairs", ".xlsx" ]) do |file|
      file.binmode
      file.write(response.body)
      file.flush
      yield Roo::Excelx.new(file.path)
    end
  end

  shared_examples "consistent transmittal generation" do |endpoint|
    it "generates and saves combined FIT defaults matching the preview and tax block" do
      original_amounts = item.attributes
      get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: period.id }
      expect(response.parsed_body.fetch("tax_totals")).to include("fit" => 207.09, "total_drt_deposit" => 207.09)

      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id }
      text = pdf_text
      expect(text).to include("FIT Deposit Total: $207.09", "Employee FIT Withheld $207.09")
      expect(period.reload.transmittal.notes.join).to include("FIT Deposit Total: $207.09")
      expect(item.reload.attributes).to eq(original_amounts)
    end

    it "includes extra-only FIT in the preview, default instruction, and PDF" do
      item.update_columns(withholding_tax: 0, additional_withholding: 10)
      get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: period.id }
      expect(response.parsed_body.fetch("tax_totals")).to include("fit" => 10.0, "total_drt_deposit" => 10.0)

      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id }
      expect(pdf_text).to include("FIT Deposit Total: $10.00", "Employee FIT Withheld $10.00")
    end

    it "upgrades exact legacy automatic notes in the preview and generated cover" do
      legacy_notes = [ "FICA Obligation (Social Security & Medicare): $611.50", "FIT Deposit Total: $197.09 — check to Treasurer of Guam for DRT" ]
      Transmittal.create!(company: company, pay_period: period, notes: legacy_notes)
      get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: period.id }
      expect(response.parsed_body.dig("saved_transmittal", "notes").last).to include("$207.09")
      expect(period.reload.transmittal.notes).to eq(legacy_notes) # Preview is read-only.
      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id, notes: legacy_notes }
      expect(pdf_text).to include("FIT Deposit Total: $207.09")
      expect(period.reload.transmittal.notes.last).to include("$207.09")
    end

    it "recognizes automatic notes formatted with thousands separators by the editor" do
      item.update_columns(withholding_tax: 1197.09)
      legacy_notes = [ "FICA Obligation (Social Security & Medicare): $611.50", "FIT Deposit Total: $1,197.09 — check to Treasurer of Guam for DRT" ]
      Transmittal.create!(company: company, pay_period: period, notes: legacy_notes)
      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id }
      expect(pdf_text).to include("FIT Deposit Total: $1,207.09")
    end

    it "preserves saved edited cover context when later exports omit parameters" do
      check = create(:non_employee_check, company: company, pay_period: period, payable_to: "Synthetic Payee")
      saved = Transmittal.create!(company: company, pay_period: period,
        preparer_name: "Saved Preparer", notes: [ "Client will arrange their own deposit; retain $197.09 reference." ],
        report_list: [ "Client-edited list" ], transmittal_date: Date.new(2026, 10, 22),
        payroll_check_numbers: %w[888 891], non_employee_check_numbers: { check.id.to_s => "NEW987" },
        custom_entries: [ { "title" => "Saved enclosure", "details" => [ "Keep this detail" ] } ])
      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id }
      expect(pdf_text).to include("Saved Preparer", "retain $197.09 reference", "10/22/2026", "888, 891", "NEW987", "Saved enclosure", "Keep this detail")
      expect(saved.reload.notes).to eq([ "Client will arrange their own deposit; retain $197.09 reference." ])
      expect(saved.preparer_name).to eq("Saved Preparer")
      if endpoint == "transmittal_log_pdf"
        expect(saved.report_list).to eq([ "Client-edited list" ])
      else
        expect(saved.report_list).to eq(TransmittalLogPdfGenerator::REPORT_LIST)
      end
    end

    it "retains an explicit empty notes list instead of restoring defaults" do
      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id, notes: [] }, as: :json
      expect(pdf_text).not_to include("FIT Deposit Total:")
      expect(period.reload.transmittal.notes).to eq([])
      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id }
      expect(pdf_text).not_to include("FIT Deposit Total:")
    end

    it "uses generated defaults for nullable saved notes and report lists" do
      saved = Transmittal.create!(company: company, pay_period: period, notes: nil, report_list: nil)

      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id }

      expect(pdf_text).to include("FIT Deposit Total: $207.09", "Payroll Summary by Employee")
      expect(saved.reload.notes).to eq(TransmittalLogPdfGenerator.default_notes(period))
      expect(saved.report_list).to eq(TransmittalLogPdfGenerator::REPORT_LIST)
    end

    it "clears saved nonemployee overrides over JSON and retains the empty map on later generation" do
      check = create(:non_employee_check, company: company, pay_period: period,
        payable_to: "Synthetic Payee", check_number: "ORIGINAL987")
      saved = Transmittal.create!(company: company, pay_period: period,
        non_employee_check_numbers: { check.id.to_s => "OVERRIDE987" })

      post "/api/v1/admin/reports/#{endpoint}", params: {
        pay_period_id: period.id, non_employee_check_numbers: {}
      }, as: :json

      expect(pdf_text).to include("ORIGINAL987")
      expect(pdf_text).not_to include("OVERRIDE987")
      expect(saved.reload.non_employee_check_numbers).to eq({})
      get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: period.id }
      expect(response.parsed_body.dig("saved_transmittal", "non_employee_check_numbers")).to eq({})
      post "/api/v1/admin/reports/#{endpoint}", params: { pay_period_id: period.id }
      expect(pdf_text).to include("ORIGINAL987")
      expect(saved.reload.non_employee_check_numbers).to eq({})
    end
  end

  include_examples "consistent transmittal generation", "transmittal_log_pdf"
  include_examples "consistent transmittal generation", "full_print_package_pdf"

  it "retains explicitly empty report lists on standalone transmittals" do
    saved = Transmittal.create!(company: company, pay_period: period, report_list: [ "Previously enclosed" ])
    post "/api/v1/admin/reports/transmittal_log_pdf", params: { pay_period_id: period.id, report_list: [] }, as: :json
    expect(pdf_text).not_to include("Previously enclosed", "Payroll Summary by Employee")
    expect(saved.reload.report_list).to eq([])
    post "/api/v1/admin/reports/transmittal_log_pdf", params: { pay_period_id: period.id }
    expect(pdf_text).not_to include("Payroll Summary by Employee")
    expect(saved.reload.report_list).to eq([])
  end

  it "returns signoff notes verbatim even when they match legacy transmittal defaults" do
    notes = TransmittalLogPdfGenerator.default_notes(period, include_additional: false)
    saved = CheckSignoffSheet.create!(company: company, pay_period: period,
      entries: [ { "name" => "Fixture, Casey", "check_number" => "123" } ], notes: notes)
    original = saved.attributes

    get "/api/v1/admin/reports/check_signoff_preview", params: { pay_period_id: period.id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("saved_signoff", "notes")).to eq(notes)
    expect(saved.reload.attributes).to eq(original)
    post "/api/v1/admin/reports/check_signoff_pdf", params: { pay_period_id: period.id }
    expect(pdf_text).to include("FIT Deposit Total: $197.09")
    expect(pdf_text).not_to include("FIT Deposit Total: $207.09")
    expect(saved.reload.attributes).to eq(original)
  end

  it "exports additional and combined FIT in the downloaded Employee Summary Totals sheet" do
    create(:payroll_item, company: company, employee: create(:employee, company: company), pay_period: period,
      gross_pay: 100, withholding_tax: 2.91, additional_withholding: 7.25)
    create(:payroll_item, company: company, employee: create(:employee, :contractor, company: company),
      pay_period: period, employment_type: "contractor", gross_pay: 200, withholding_tax: 0, additional_withholding: 99)
    create(:payroll_item, :voided, company: company, employee: create(:employee, company: company),
      pay_period: period, payroll_reversed_at: Time.current, withholding_tax: 1000, additional_withholding: 1000)

    get "/api/v1/admin/reports/payroll_summary_by_employee_xlsx", params: { pay_period_id: period.id }

    with_workbook do |workbook|
      totals = workbook.sheet("Totals").to_a.drop(1).to_h
      expect(totals).to include("Employees" => 2, "Base FIT" => 200,
        "Additional FIT Withholding" => 17.25, "Total FIT (Base + Additional)" => 217.25)
      contractor_totals = workbook.sheet("Contractor Totals").to_a.drop(1).to_h
      expect(contractor_totals).to include("Additional FIT Withholding" => 99, "Total FIT (Base + Additional)" => 99)
    end
  end

  it "uses saved contractor rate bases consistently in CSV and XLSX after employee profile changes" do
    expected = {}
    [ [ "flat_fee", "hourly", "USD/flat fee" ],
      [ "hourly", "flat_fee", "USD/hour (primary rate; see Earnings Detail for all rates)" ],
      [ nil, "hourly", "USD (contractor rate basis not recorded)" ] ].each do |saved_type, current_type, basis|
      worker = create(:employee, :contractor, company: company, contractor_pay_type: saved_type || "flat_fee")
      create(:payroll_item, company: company, employee: worker, pay_period: period,
        employment_type: "contractor", pay_rate: 500, gross_pay: 500,
        calculation_context_snapshot: { "employee" => { "contractor_pay_type" => saved_type }.compact })
      worker.update!(contractor_pay_type: current_type)
      expected[worker.full_name] = basis
    end

    get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok)
    csv_rows = CSV.parse(response.body, headers: true)
    expected.each do |name, basis|
      expect(csv_rows.find { |row| row["Employee Name"] == name }["Rate Basis"]).to eq(basis)
    end

    get "/api/v1/admin/reports/payroll_register_xlsx", params: { pay_period_id: period.id }
    with_workbook do |workbook|
      rows = workbook.sheet("Contractors").to_a
      header_index = rows.index { |row| row.include?("Rate Basis") }
      headers = rows.fetch(header_index)
      values = rows.drop(header_index + 1).map { |row| headers.zip(row).to_h }
      expected.each do |name, basis|
        expect(values.find { |row| row["Employee Name"] == name }["Rate Basis"]).to eq(basis)
      end
    end
  end

  it "includes the advertised empty loan report in the actual package" do
    post "/api/v1/admin/reports/full_print_package_pdf", params: { pay_period_id: period.id, report_list: [ "Not attached" ] }
    reader = pdf_reader
    expect(reader.pages.first.text).to include("Employee Installment Loan Report")
    expect(reader.pages.last.text).to include("Employee Installment Loan Report", "No employee loans found.")
    expect(reader.pages.first.text).not_to include("Not attached")
    expect(period.reload.transmittal.report_list).to eq(TransmittalLogPdfGenerator::REPORT_LIST)
  end

  it "includes paid-off balance-tracked loans and the pay-date balance in the package" do
    loan = EmployeeLoan.create!(employee: employee, company: company, name: "Repaid tool advance",
      original_amount: 100, current_balance: 0, payment_amount: 10,
      start_date: Date.new(2026, 1, 1), status: "paid_off", paid_off_date: Date.new(2026, 10, 20))
    loan.loan_transactions.create!(transaction_type: "payment", amount: 100,
      balance_before: 100, balance_after: 0, transaction_date: Date.new(2026, 10, 20))
    post "/api/v1/admin/reports/full_print_package_pdf", params: { pay_period_id: period.id }
    expect(pdf_reader.pages.last.text.gsub(/\s+/, " ")).to include("Repaid tool advance", "Balance as of 10/15/2026: $100.00", "Status: Active")
  end

  it "downloads original saved UTC-date check bytes without invalidating the prepared package" do
    company.update!(check_stock_type: "bottom_check", check_offset_x: 0, check_offset_y: 0)
    check = create(:non_employee_check, company: company, pay_period: period,
      check_number: "SYN987", amount: 207.09, created_at: Time.utc(2026, 10, 21, 14, 42, 58))
    generator = NonEmployeeCheckGenerator.new(check)
    legacy_payload = generator.render_input_payload
    expect(legacy_payload.fetch("reference_rows")).to include([ "Created", "10/21/2026" ])
    stored_bytes = "%PDF-1.4 original immutable UTC-date PDF bytes"
    run = CheckPrintRun.create!(company: company, pay_period: period, created_by: user,
      status: "prepared", check_stock_type: "bottom_check", starting_slot: 1, selected_count: 1,
      calibration_snapshot: { "check_offset_x" => 0, "check_offset_y" => 0, "check_layout_config" => company.check_layout_config },
      manifest: [ { "key" => "non_employee_check:#{check.id}", "source_type" => "non_employee_check", "source_id" => check.id,
        "check_number" => check.check_number, "amount" => "207.09", "source_updated_at" => check.updated_at.iso8601(6),
        "render_input_digest" => CheckPrintRenderFingerprint.for_payload(legacy_payload) } ],
      storage_key: "synthetic-saved-check", filename: "original.pdf", generated_at: Time.utc(2026, 10, 21, 14, 43),
      sha256: Digest::SHA256.hexdigest(stored_bytes), byte_size: stored_bytes.bytesize)
    allow_any_instance_of(Api::V1::Admin::CheckPrintRunsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::CheckPrintRunsController).to receive(:current_user).and_return(user)
    allow_any_instance_of(R2StorageService).to receive(:download).with(run.storage_key).and_return(stored_bytes)
    expect_any_instance_of(NonEmployeeCheckGenerator).not_to receive(:generate)

    get "/api/v1/admin/check_print_runs/#{run.id}/pdf"
    expect(response).to have_http_status(:ok), response.body
    expect(response.body).to eq(stored_bytes)
    expect(run.reload.sha256).to eq(Digest::SHA256.hexdigest(stored_bytes))
  end

  it "exports XLSX metadata, saved totals, rate units, and explicit FIT components" do
    item.update_columns(calculation_context_snapshot: { "employee" => { "salary_type" => "annual" } }, employment_type: "salary", pay_rate: 52000)
    get "/api/v1/admin/reports/payroll_register_xlsx", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok)
    file = Tempfile.new([ "report-repairs", ".xlsx" ])
    file.binmode
    file.write(response.body)
    file.close
    sheet = Roo::Excelx.new(file.path).sheet("Employees")
    expect(sheet.row(1)).to include(company.name)
    expect(sheet.row(2).first).to include("Work period: 2026-09-16 to 2026-09-30", "Pay date: 2026-10-15")
    headers = sheet.row(4)
    values = headers.zip(sheet.row(5)).to_h
    totals = headers.zip(sheet.row(6)).to_h
    expect(values).to include("Pay Rate" => 52000, "Rate Basis" => "USD/year (annual salary)",
      "Regular Hours" => 76, "Overtime Hours" => 5, "Combined Hours" => 81,
      "Base FIT" => 197.09, "Additional W/H" => 10, "Total FIT (Base + Additional)" => 207.09)
    expect(totals).to include("Employee Name" => "TOTALS", "Gross Pay" => 3996.67,
      "Total Deductions" => 512.84, "Net Pay" => 3483.83, "Total FIT (Base + Additional)" => 207.09, "Combined Hours" => 81)
    expect(totals["Pay Rate"]).to be_nil
    expect(sheet.excelx_format(5, headers.index("Gross Pay") + 1)).to include("0.00")
  ensure
    file&.unlink
  end
end
