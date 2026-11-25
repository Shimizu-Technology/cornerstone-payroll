# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe DemoCompany::QuickbooksSample do
  around { |example| Dir.mktmpdir("hfk-quickbooks") { |dir| @dir = dir; example.run } }

  let(:result) { described_class.new(output_dir: @dir).call }

  def uploads
    result.files.map { |path| Rack::Test::UploadedFile.new(path, "application/vnd.ms-excel", true, original_filename: File.basename(path)) }
  end

  it "writes a bundle the real QuickBooks history parser accepts without errors" do
    adapter = HistoricalPayrollImports::Registry.default.fetch!(HistoricalPayrollImports::Registry::DEFAULT_SOURCE_SYSTEM)
    parsed = adapter.parse(files: uploads)

    expect(Array(parsed.errors)).to be_empty
    expect(parsed.paychecks.size).to eq(6)
    expect(parsed.paychecks.map { |paycheck| paycheck.respond_to?(:pay_date) ? paycheck.pay_date : paycheck[:pay_date] }.uniq.size).to eq(2)
  end

  it "writes one matchable text page per stub with no SSN, bank or MICR details" do
    pages = PDF::Reader.new(result.stub_pdf).pages.map(&:text)
    expect(pages.size).to eq(6)
    check_page = pages.find { |text| text.include?("Check no. 901") }
    expect(check_page).to match(EmployeeDocuments::QuickbooksStubMatches::DATE)
    expect(check_page).to match(EmployeeDocuments::QuickbooksStubMatches::NET)
    expect(check_page).to match(EmployeeDocuments::QuickbooksStubMatches::CHECK_NUMBER)
    pages.each do |text|
      expect(EmployeeDocuments::QuickbooksStubNumbers.possible_ssn?(text)).to be(false)
      expect(text).not_to match(/routing|account|⑆|⑈|demo|sample/i)
    end
  end

  it "dates every paycheck before the first seeded native payday" do
    dates = described_class.stub_pages.map { |page| Date.strptime(page[:pay_date], "%m/%d/%Y") }
    expect(dates.max).to be < DemoCompany::Seed::FIRST_PERIOD_START
  end
end
