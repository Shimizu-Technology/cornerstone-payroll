# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

module OfficialQuarterlyPdfFieldHelpers
  def template_fields(page_number)
    reader = PDF::Reader.new(described_class::TEMPLATE_PATH.to_s)
    annotations = reader.pages.fetch(page_number - 1).attributes[:Annots]
    annotations = reader.objects[annotations] if annotations.is_a?(PDF::Reader::Reference)
    annotations.to_h do |reference|
      widget = reader.objects[reference]
      name = widget.fetch(:T).b
      name = name.byteslice(2..).force_encoding("UTF-16BE").encode("UTF-8") if name.start_with?("\xFE\xFF".b)
      [ name, widget.fetch(:Rect) ]
    end
  end

  def text_in_field(page, rect)
    left, bottom, right, top = rect
    page.runs.select { |run| run.x.between?(left, right) && run.y.between?(bottom, top) }
      .sort_by(&:x).map(&:text).join
  end
end

RSpec.describe QuarterlyComplianceOfficialForms::Form941 do
  include OfficialQuarterlyPdfFieldHelpers
  let(:report) do
    {
      meta: { company_name: "Synthetic Quarterly PDF QA", ein: "98-0000015", year: 2026, quarter: 2,
        quarter_end: "2026-06-30", company_address_line1: "Synthetic QA address", company_city: "Hagatna",
        company_state: "GU", company_zip: "96910" },
      federal_941: { report: { employer_info: {}, lines: {
        line1_employee_count: 4, line5a_ss_wages: 20, line5a_ss_combined_tax: 2.48,
        line5b_ss_tips: 0, line5b_ss_tips_combined_tax: 0, line5c_medicare_wages: 20,
        line5c_medicare_combined_tax: 0.58, line5d_add_medicare_wages: 0, line5d_add_medicare_tax: 0,
        line5e_total_ss_medicare: 3.06, line6_total_taxes_before_adj: 3.06,
        line7_adj_fractions_cents: -0.01, line10_total_taxes_after_adj: 3.05, line12_total_after_credits: 3.05
      } }, deposit_schedule: { suggested_schedule: "monthly", schedule_b_required: false } }
    }
  end

  it "rejects unsupported and missing report years even when edited fields claim 2026" do
    [ 2025, 2027, nil, 2026.9, 2026.0, "2026.9" ].each do |year|
      report[:meta][:year] = year
      expect { described_class.new(report: report, fields: { year: 2026 }) }
        .to raise_error(OfficialPdfOverlay::TemplateUnavailableError, /only for tax year 2026/)
    end
  end

  it "accepts the exact supported decimal year string" do
    report[:meta][:year] = "2026"
    expect(described_class.template_status("2026")[:available]).to be(true)
    expect(described_class.new(report: report).generate).to start_with("%PDF")
  end

  it "places every supported tax total in its labeled March2026 template fields without filling neighboring lines" do
    fields = template_fields(1)
    page = PDF::Reader.new(StringIO.new(described_class.new(report: report).generate)).pages.first
    # These official field IDs identify5e,6,7,10,12 in the immutable IRS form,
    # independently of the application's overlay rectangle constants.
    { 33 => [ "3", "06" ], 37 => [ "3", "06" ], 39 => [ "-0", "01" ],
      45 => [ "3", "05" ], 49 => [ "3", "05" ] }.each do |index, amounts|
      expect(text_in_field(page, fields.fetch("f1_#{index}[0]"))).to eq(amounts.first)
      expect(text_in_field(page, fields.fetch("f1_#{index + 1}[0]"))).to eq(amounts.last)
    end
    # 5f,8,9,11 have no supplied reviewed value and must remain blank.
    [ 35, 41, 43, 47 ].each do |index|
      expect(text_in_field(page, fields.fetch("f1_#{index}[0]"))).to eq("")
      expect(text_in_field(page, fields.fetch("f1_#{index + 1}[0]"))).to eq("")
    end
  end

  it "keeps the positive adjustment and reviewed overrides in their own official fields" do
    fields = template_fields(1)
    overrides = { lines: { line6_total_taxes_before_adj: 15.30, line7_adj_fractions_cents: 0.01,
      line10_total_taxes_after_adj: 15.31, line12_total_after_credits: 15.31 } }
    page = PDF::Reader.new(StringIO.new(described_class.new(report: report, fields: overrides).generate)).pages.first

    expect(text_in_field(page, fields.fetch("f1_37[0]"))).to eq("15")
    expect(text_in_field(page, fields.fetch("f1_38[0]"))).to eq("30")
    expect(text_in_field(page, fields.fetch("f1_39[0]"))).to eq("0")
    expect(text_in_field(page, fields.fetch("f1_40[0]"))).to eq("01")
    [ 45, 49 ].each do |index|
      expect(text_in_field(page, fields.fetch("f1_#{index}[0]"))).to eq("15")
      expect(text_in_field(page, fields.fetch("f1_#{index + 1}[0]"))).to eq("31")
    end
  end

  it "emits a static draft without orphan input widgets while preserving the IRS source form" do
    reader = PDF::Reader.new(StringIO.new(described_class.new(report: report).generate))
    expect(reader.objects[reader.objects.trailer[:Root]][:AcroForm]).to be_nil
    reader.pages.each do |page|
      annotations = page.attributes[:Annots]
      annotations = reader.objects[annotations] if annotations.is_a?(PDF::Reader::Reference)
      Array(annotations).each do |reference|
        annotation = reference.is_a?(PDF::Reader::Reference) ? reader.objects[reference] : reference
        expect(annotation[:Subtype]).not_to eq(:Widget)
      end
    end
    source = PDF::Reader.new(described_class::TEMPLATE_PATH.to_s)
    expect(source.objects[source.objects.trailer[:Root]][:AcroForm]).not_to be_nil
    expect(template_fields(1)).to have_key("f1_39[0]")
  end

  it "retains non-input annotations in the static quarterly output" do
    link = { is_reference_only: true, referenced_object: { Subtype: :Link, URI: "https://www.irs.gov/Form941" } }
    widget = { is_reference_only: true, referenced_object: { Subtype: :Widget } }
    page = { Annots: [ widget, link ] }

    described_class.allocate.send(:prepare_template_page, page)

    expect(page[:Annots]).to eq([ link ])
  end

  it "preserves page2 monthly liability positions and all three official pages" do
    report[:federal_941][:report][:monthly_liability] = [
      { total_liability: 1000.01 }, { total_liability: 1000.02 }, { total_liability: 1000.03 }
    ]
    reader = PDF::Reader.new(StringIO.new(described_class.new(report: report,
      fields: { line12_total_after_credits: 3000.06 }).generate))
    fields = template_fields(2)

    expect(reader.page_count).to eq(3)
    reader.pages.each { |page| expect(page.text).to include("DRAFT", "NOT FILED") }
    expect(reader.pages.last.text).to include("Payment Voucher")
    [ [ 1, "1000", "01" ], [ 3, "1000", "02" ], [ 5, "1000", "03" ], [ 7, "3000", "06" ] ].each do |index, dollars, cents|
      expect(text_in_field(reader.pages.second, fields.fetch("f2_#{index}[0]"))).to eq(dollars)
      expect(text_in_field(reader.pages.second, fields.fetch("f2_#{index + 1}[0]"))).to eq(cents)
    end
  end
end

RSpec.describe OfficialPdfOverlay do
  it "preserves decreasing fractional-dollar adjustments after currency rounding" do
    formatter = described_class.allocate
    { "-0.01" => [ "-0", "01" ], "-0.99" => [ "-0", "99" ], "-1.01" => [ "-1", "01" ],
      "0.01" => [ "0", "01" ], "-0.004" => [ "0", "00" ] }.each do |amount, expected|
      expect(formatter.send(:money_parts, amount)).to eq(expected)
    end
  end
end

RSpec.describe QuarterlyComplianceOfficialForms::ScheduleB do
  include OfficialQuarterlyPdfFieldHelpers

  it "keeps daily and monthly totals in their labeled source fields after shared formatter changes" do
    report = {
      meta: { company_name: "Synthetic Quarterly PDF QA", ein: "98-0000015", year: 2026, quarter: 2,
        quarter_end: "2026-06-30" },
      pay_periods: [ { pay_date: "2026-04-01", federal_941_liability: 100.25 },
        { pay_date: "2026-04-01", federal_941_liability: 50.75 },
        { pay_date: "2026-05-15", federal_941_liability: 25.01 },
        { pay_date: "2026-06-30", federal_941_liability: 30.02 } ]
    }
    page = PDF::Reader.new(StringIO.new(described_class.new(report: report).generate)).pages.first
    fields = template_fields(1)
    # Source IDs: month1/day1, month2/day15, month3/day30, three month totals, quarter total.
    [ [ 15, "151", "00" ], [ 107, "25", "01" ], [ 201, "30", "02" ],
      [ 77, "151", "00" ], [ 141, "25", "01" ], [ 205, "30", "02" ], [ 207, "206", "03" ] ].each do |index, dollars, cents|
      expect(text_in_field(page, fields.fetch("f1_#{index}[0]"))).to eq(dollars)
      expect(text_in_field(page, fields.fetch("f1_#{index + 1}[0]"))).to eq(cents)
    end
    expect(page.text).to include("Synthetic Quarterly PDF QA", "DRAFT", "NOT FILED")
  end
end
