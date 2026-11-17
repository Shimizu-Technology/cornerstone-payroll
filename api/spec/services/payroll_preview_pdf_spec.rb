# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe PayrollPreviewPdf do
  let(:company) { create(:company, check_stock_type: "top_check") }
  let(:period) { create(:pay_period, :approved, company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 123.45, net_pay: 100, withholding_tax: 10, social_security_tax: 8, medicare_tax: 3, additional_withholding: 2.45, ytd_gross: 123.45, ytd_net: 100, ytd_withholding_tax: 10, ytd_social_security_tax: 8, ytd_medicare_tax: 3) }

  def pdf_pages(data)
    PDF::Reader.new(StringIO.new(data)).pages
  end

  describe "preview parts" do
    let!(:paper) { item }
    let!(:deposit) do
      create(:payroll_item, company: company, pay_period: period,
        employee: create(:employee, company: company, first_name: "Alex", last_name: "Adams"),
        payment_delivery_method: "direct_deposit", gross_pay: 200, net_pay: 180)
    end
    let!(:zero) do
      create(:payroll_item, company: company, pay_period: period,
        employee: create(:employee, company: company, first_name: "Zoe", last_name: "Adams"), gross_pay: 50, net_pay: 0)
    end
    let!(:empty) { create(:payroll_item, company: company, pay_period: period, gross_pay: 0, net_pay: 0) }

    before do
      paper.employee.update!(first_name: "Paper", last_name: "Worker", payment_delivery_method: "direct_deposit")
      paper.update!(payment_delivery_method: "paper_check")
      zero.update!(payment_delivery_method: "paper_check")
    end

    { nil => [ "Paper Worker", "Alex Adams", "Zoe Adams" ],
      "checks" => [ "Paper Worker" ], "stubs" => [ "Alex Adams", "Zoe Adams" ],
      "all_stubs" => [ "Alex Adams", "Zoe Adams", "Paper Worker" ] }.each do |part, names|
      it "renders #{part || 'combined'} using run methods, without empty rows and in name order" do
        rendered = []
        allow(CheckGenerator).to receive(:generate_preview_batch).and_wrap_original do |original, checks, **options|
          rendered.concat(checks.map { |row| row.employee.full_name })
          original.call(checks, **options)
        end
        allow(PayStubGenerator).to receive(:new).and_wrap_original do |original, row, **options|
          rendered << row.employee.full_name
          original.call(row, **options)
        end
        pages = pdf_pages(described_class.generate(pay_period: period, company: company, part: part))
        expect(pages.size).to eq(names.size)
        expect(rendered).to eq(names)
        expect(rendered).not_to include(empty.employee.full_name)
      end
    end

    it "respects a run override from paper check to deposit" do
      paper.update!(payment_delivery_method: "direct_deposit")
      paper.employee.update!(payment_delivery_method: "paper_check")
      allow(PayStubGenerator).to receive(:new).and_call_original
      expect(PayStubGenerator).to receive(:new).with(have_attributes(id: paper.id), preview: true).and_call_original
      described_class.generate(pay_period: period, company: company, part: "stubs")
    end
  end

  it "renders first-class check and stub previews with identical page dimensions and a replaced footer" do
    normal = pdf_pages(CheckGenerator.new(item).generate)
    preview = pdf_pages(CheckGenerator.new(item, preview: true).generate)
    expect(preview.size).to eq(normal.size)
    expect(preview.first.attributes[:MediaBox]).to eq(normal.first.attributes[:MediaBox])
    expect(preview.first.text).to include("PREVIEW")
    expect(preview.first.text).not_to include("VOID", "NOT FINAL")
    pdf_pages(PayStubGenerator.new(item, preview: true).generate).each do |page|
      expect(page.text).to include("PREVIEW")
      expect(page.text).not_to match(/VOID|NOT FINAL|official earnings statement|Generated on/)
    end
    expect(pdf_pages(PayStubGenerator.new(item).generate).first.text).to include("official earnings statement")
  end

  it "watermarks every page of a paginated pay stub and replaces every footer" do
    item.update!(non_taxable_pay: 20,
      custom_deductions: 20.times.map { |index| { "label" => "Deduction #{index + 1}", "amount" => 1 } })
    pages = pdf_pages(PayStubGenerator.new(item, preview: true).generate)
    expect(pages.size).to eq(2)
    pages.each do |page|
      # PDF text extraction can split the rotated letters; the banner and
      # replacement footer remain searchable on every statement page.
      expect(page.text.scan("PREVIEW").size).to be >= 2
      expect(page.text).not_to include("official earnings statement", "VOID", "NOT FINAL")
    end
  end

  it "marks every page of a multi-page First Hawaiian check batch PREVIEW" do
    company.update!(check_stock_type: "first_hawaiian_4up")
    items = 5.times.map { create(:payroll_item, company: company, pay_period: period, employee: create(:employee, company: company), gross_pay: 100, net_pay: 90) }
    data = FirstHawaiianFourUpCheckGenerator.new(company: company, payroll_items: items, preview: true).generate
    pages = pdf_pages(data)
    expect(pages.size).to eq(2)
    pages.each do |page|
      expect(page.text).to include("PREVIEW")
      expect(page.text).not_to include("VOID", "NOT FINAL")
    end
  end

  it "keeps the caller's order for unnumbered First Hawaiian preview checks" do
    company.update!(check_stock_type: "first_hawaiian_4up")
    names = %w[Adams Baker Chen Diaz Evans Fujita Garcia]
    items = names.map do |last|
      create(:payroll_item, company: company, pay_period: period, gross_pay: 100, net_pay: 90,
        employee: create(:employee, company: company, first_name: "Pat", last_name: last))
    end
    generator = FirstHawaiianFourUpCheckGenerator.new(company: company, payroll_items: items, preview: true)
    expect(generator.send(:entries).map(&:payee)).to eq(names.map { |last| "Pat #{last}" })
  end

  it "suppresses any legacy assigned check reference in a preview" do
    item.update_columns(check_number: "987654321")
    company.update!(check_memo_template: "Payroll {check_number}")
    expect(pdf_pages(CheckGenerator.new(item, preview: true).generate).first.text).not_to include("987654321")
    expect(pdf_pages(PayStubGenerator.new(item, preview: true).generate).first.text).not_to include("987654321")
  end

  %w[approved committed].each do |status|
    it "matches check-stub and pay-stub YTD for #{status} live payroll, counting the current check once" do
      prior = create(:pay_period, :committed, company: company, start_date: period.start_date - 14, end_date: period.end_date - 14, pay_date: period.pay_date - 14)
      create(:payroll_item, company: company, employee: employee, pay_period: prior, gross_pay: 200, net_pay: 170, withholding_tax: 15, social_security_tax: 10, medicare_tax: 4, additional_withholding: 1)
      period.update_columns(status: status)
      item.update_columns(ytd_gross: 323.45, ytd_net: 270, ytd_withholding_tax: 25, ytd_social_security_tax: 18, ytd_medicare_tax: 7)
      check = CheckGenerator.new(item)
      stub = PayStubGenerator.new(item)
      ytd = check.send(:ytd)
      expect(ytd.values).to all(be_a(BigDecimal))
      expect(ytd).to include(gross: 323.45.to_d, net: 270.to_d, fit: 25.to_d, ss: 18.to_d, med: 7.to_d, addl_wh: 3.45.to_d, taxes: 53.45.to_d)
      expect(check.render_input_payload.dig("summary", "ytd_gross")).to eq("323.45")
      expect(stub.send(:pay_ytd_total)).to eq(ytd[:gross])
      expect(stub.send(:payroll_item).ytd_net.to_d).to eq(ytd[:net])
      expect(pdf_pages(check.generate).first.text).to include("323.45", "25.00", "18.00", "7.00")
      expect(pdf_pages(stub.generate).first.text).to include("323.45", "270.00", "25.00", "18.00", "7.00")
    end
  end

  it "does not double count calculated or approved test-workspace periods already in reportable scope" do
    company.update!(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company: create(:company, organization: company.organization),
      migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
    %w[calculated approved].each do |status|
      period.update_columns(status: status)
      expect(PayPeriod.reportable_for_company(company).exists?(period.id)).to be(true)
      expect(CheckGenerator.new(item).send(:ytd)[:gross]).to eq(123.45.to_d)
    end
  end
end
