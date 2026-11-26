# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe DemoCompany::QuickbooksSample do
  around { |example| Dir.mktmpdir("hfk-quickbooks") { |dir| @dir = dir; example.run } }

  let!(:annual_config) { create(:annual_tax_config, tax_year: 2026, ss_wage_base: 184_500) }
  let(:result) { described_class.new(output_dir: @dir).call }

  def uploads
    result.files.map { |path| Rack::Test::UploadedFile.new(path, "application/vnd.ms-excel", true, original_filename: File.basename(path)) }
  end

  it "writes January–July history the real parser accepts and reconciles to its Tax and Wage Summaries" do
    adapter = HistoricalPayrollImports::Registry.default.fetch!(HistoricalPayrollImports::Registry::DEFAULT_SOURCE_SYSTEM)
    parsed = adapter.parse(files: uploads)

    expect(Array(parsed.errors)).to be_empty
    expect(parsed.paychecks.size).to eq(DemoCompany::Roster.quickbooks_people.size * 14)
    expect(parsed.tax_wage_reports.size).to eq(3)
    expect(parsed.tax_wage_reconciliation).to include("passed" => true)
  end

  it "writes one matchable text page per paycheck, a month per PDF, with no SSN, bank or MICR details" do
    expect(result.stub_pdfs.size).to eq(7)
    readers = result.stub_pdfs.map { |path| PDF::Reader.new(path) }
    expect(readers.map(&:page_count)).to all(be <= EmployeeDocuments::QuickbooksStubPdf::MAX_PAGES)
    pages = readers.flat_map { |reader| reader.pages.map(&:text) }
    expect(pages.size).to eq(described_class.paychecks.size)
    check_page = pages.find { |text| text.include?("Check no. #{described_class::FIRST_CHECK_NUMBER}") }
    expect(check_page).to match(EmployeeDocuments::QuickbooksStubMatches::DATE)
    expect(check_page).to match(EmployeeDocuments::QuickbooksStubMatches::NET)
    expect(check_page).to match(EmployeeDocuments::QuickbooksStubMatches::CHECK_NUMBER)
    pages.each do |text|
      expect(EmployeeDocuments::QuickbooksStubNumbers.possible_ssn?(text)).to be(false)
      expect(text).to include("101 Harbor Finch Way, Hagåtña, GU 96910")
      expect(text).to match(/Employee: Employee 0[1-8]/)
      expect(text).not_to match(/routing|account|⑆|⑈|demo|sample|Marine Corps|Chalan|Route 8/i)
    end
  end

  it "keeps every roster and QuickBooks figure as exact BigDecimal money" do
    DemoCompany::Roster::PEOPLE.each do |person|
      expect(person[:rate]).to be_a(BigDecimal)
      Array(person[:tips]).each { |tip| expect(tip).to be_a(BigDecimal) }
      expect(person[:uniform_deduction]).to be_a(BigDecimal) if person[:uniform_deduction]
      expect(person.dig(:raise, :rate)).to be_a(BigDecimal) if person[:raise]
    end
    described_class.paychecks.each do |paycheck|
      %i[gross fit ss med net].each do |field|
        expect(paycheck[field]).to be_a(BigDecimal)
        expect(paycheck[field]).to eq(paycheck[field].round(2))
      end
      expect(paycheck[:gross] - paycheck[:fit] - paycheck[:ss] - paycheck[:med]).to eq(paycheck[:net])
    end
  end

  it "ends the history before the first native payday" do
    expect(described_class.paychecks.map { |paycheck| paycheck[:pay_date] }.max).to be < DemoCompany::Roster.native_periods.first[:pay_date]
    expect(described_class.paychecks.map { |paycheck| paycheck[:pay_date] }.max).to be <= Date.new(2026, 7, 31)
  end
end
