# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::Adapters::MosaRevel do
  let(:company) { create(:company, name: "MoSa Test", payroll_intake_source_types: [ "mosa_revel" ]) }
  let(:admin) { create(:user, company: company, role: "admin") }
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 9, 13),
      end_date: Date.new(2026, 9, 26),
      pay_date: Date.new(2026, 10, 2)
    )
  end
  let!(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example", pay_rate: 18.50) }

  def uploaded_file(path, filename:, content_type:)
    ActionDispatch::Http::UploadedFile.new(
      tempfile: File.open(path, "rb"),
      filename: filename,
      type: content_type
    )
  end

  def revel_upload(period_start: pay_period.start_date, period_end: pay_period.end_date)
    path = build_revel_pdf(
      [ { name: "Example, Avery", regular_hours: 40, overtime_hours: 2, regular_pay: 9_999, overtime_pay: 999 } ],
      period_start: period_start,
      period_end: period_end
    )
    uploaded_file(
      path,
      filename: "payroll_#{period_start.iso8601}_to_#{period_end.iso8601}.pdf",
      content_type: "application/pdf"
    )
  end

  def workbook_upload
    file = Tempfile.new([ "mosa-changes", ".xlsx" ])
    file.binmode
    file.write(PayrollImport::MosaSupplementalTemplate.new(pay_period).generate)
    file.close
    @workbook_files ||= []
    @workbook_files << file
    uploaded_file(
      file.path,
      filename: "mosa-payroll-changes-#{pay_period.end_date.iso8601}.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end

  def workbook_upload_with_named_component_amount
    file = Tempfile.new([ "mosa-named-component", ".xlsx" ])
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "START HERE") do |sheet|
      [
        [ "Schema version", PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION ],
        [ "Company ID", company.id ],
        [ "Pay period start", pay_period.start_date ],
        [ "Pay period end", pay_period.end_date ],
        [ "Pay date", pay_period.pay_date ],
        [ "No supplemental changes? (YES/NO)", "NO" ],
        [ "Attestation", "Confirmed" ]
      ].each { |row| sheet.add_row(row) }
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET) { |sheet| sheet.add_row(Array.new(12)) }
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET) do |sheet|
      sheet.add_row(Array.new(17))
      sheet.add_row([ employee.id, employee.full_name, "loan-42", "Owner loan", "loan", 50, "KEEP", nil, nil, nil, 300, nil, 50, 250 ])
    end
    package.serialize(file.path)
    @workbook_files ||= []
    @workbook_files << file
    uploaded_file(
      file.path,
      filename: "mosa-payroll-changes-#{pay_period.end_date.iso8601}.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end

  def workbook_upload_with_metadata(company_id: company.id, period_start: pay_period.start_date, period_end: pay_period.end_date, pay_date: pay_period.pay_date)
    file = Tempfile.new([ "mosa-metadata", ".xlsx" ])
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "START HERE") do |sheet|
      [
        [ "Schema version", PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION ],
        [ "Company ID", company_id ],
        [ "Pay period start", period_start ],
        [ "Pay period end", period_end ],
        [ "Pay date", pay_date ],
        [ "No supplemental changes? (YES/NO)", "YES" ],
        [ "Attestation", "Confirmed" ]
      ].each { |row| sheet.add_row(row) }
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET) { |sheet| sheet.add_row(Array.new(12)) }
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET) { |sheet| sheet.add_row(Array.new(17)) }
    package.serialize(file.path)
    @workbook_files ||= []
    @workbook_files << file
    uploaded_file(file.path, filename: "mosa-metadata.xlsx", content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  after do
    Array(@workbook_files).each(&:unlink)
  end

  it "uses Revel only for hours and keeps Cornerstone as the pay-rate authority" do
    extraction = described_class.new(pay_period: pay_period, company: company).extract(
      files: [ revel_upload, workbook_upload ]
    )
    source_row = extraction.fetch(:rows).find { |row| row[:row_kind] == "matched" }
    preview_row = source_row.fetch(:preview_row)

    expect(preview_row).to include(
      employee_id: employee.id,
      regular_hours: 40.0,
      overtime_hours: 2.0,
      pay_rate: 18.50
    )
    expect(preview_row.keys).not_to include(:regular_pay, :overtime_pay, :total_pay)
    expect(extraction.dig(:detected_period, :revel)).to eq(
      start_date: pay_period.start_date.iso8601,
      end_date: pay_period.end_date.iso8601
    )
  end

  it "rejects a Revel report for a different pay period" do
    expect {
      described_class.new(pay_period: pay_period, company: company).extract(
        files: [ revel_upload(period_start: Date.new(2026, 8, 30), period_end: Date.new(2026, 9, 12)) ]
      )
    }.to raise_error(ArgumentError, /but this payroll covers/)
  end

  it "blocks named recurring and loan amounts until Cornerstone setup has been reviewed" do
    expect {
      described_class.new(pay_period: pay_period, company: company).extract(
        files: [ revel_upload, workbook_upload_with_named_component_amount ]
      )
    }.to raise_error(ArgumentError, /Review that setup in Cornerstone first/)
  end

  it "rejects a generated workbook for another client" do
    expect {
      described_class.new(pay_period: pay_period, company: company).extract(
        files: [ revel_upload, workbook_upload_with_metadata(company_id: company.id + 99) ]
      )
    }.to raise_error(ArgumentError, /another Cornerstone client/)
  end

  it "rejects a generated workbook for another payroll" do
    expect {
      described_class.new(pay_period: pay_period, company: company).extract(
        files: [ revel_upload, workbook_upload_with_metadata(period_end: pay_period.end_date - 14.days) ]
      )
    }.to raise_error(ArgumentError, /but this payroll uses/)
  end

  it "retains and fingerprints the exact Revel and workbook sources with typed roles" do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: pay_period.start_date.wday,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      effective_on: pay_period.start_date,
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: admin,
      confirmed_at: Time.current,
      notes: "Confirmed for synthetic MoSa intake"
    )
    memory_storage = Class.new do
      attr_reader :objects

      def initialize
        @objects = {}
      end

      def upload(key, data, content_type:)
        objects[key] = { data: data, content_type: content_type }
      end

      def download_with_limit(key, max_bytes:)
        objects.fetch(key).fetch(:data).byteslice(0, max_bytes)
      end

      def delete(key)
        objects.delete(key)
      end
    end.new

    result = PayrollIntake::PreviewService.new(
      pay_period: pay_period,
      source_type: "mosa_revel",
      files: [ revel_upload, workbook_upload ],
      actor: admin,
      storage: memory_storage
    ).call

    expect(result[:duplicate]).to be(false)
    expect(result[:session]).to have_attributes(
      source_type: "mosa_revel",
      package_revision: 1,
      status: "previewed"
    )
    expect(result[:session].documents.in_package_order.map(&:source_role)).to eq([ "revel_hours", "supplemental_workbook" ])
    expect(result[:session].documents).to all(have_attributes(verification_status: "verified", sha256: match(/\A[0-9a-f]{64}\z/)))
    expect(result[:session].rows.first.source_payload).not_to include("regular_pay", "overtime_pay", "total_pay")
  end
end
