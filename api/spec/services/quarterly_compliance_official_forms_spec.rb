# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe QuarterlyComplianceOfficialForms::ScheduleB do
  describe "#federal_daily_liability" do
    it "groups same-day liabilities before rendering Schedule B day cells" do
      report = {
        meta: {
          company_name: "Cornerstone Tax Services",
          ein: "12-3456789",
          year: 2026,
          quarter: 2,
          quarter_end: "2026-06-30"
        },
        federal_941: { report: { employer_info: {}, lines: {} } },
        pay_periods: [
          { pay_date: "2026-04-16", federal_941_liability: 100.25 },
          { pay_date: "2026-04-16", federal_941_liability: 50.75 },
          { pay_date: "2026-05-01", federal_941_liability: 25.00 }
        ]
      }

      rows = described_class.new(report: report).send(:federal_daily_liability)

      expect(rows).to eq([
        { pay_date: "2026-04-16", month: 4, amount: 151.0 },
        { pay_date: "2026-05-01", month: 5, amount: 25.0 }
      ])
    end

    it "uses edited daily liability rows when previewing reviewed form values" do
      report = {
        meta: {
          company_name: "Cornerstone Tax Services",
          ein: "12-3456789",
          year: 2026,
          quarter: 2,
          quarter_end: "2026-06-30"
        },
        federal_941: { report: { employer_info: {}, lines: {} } },
        pay_periods: [
          { pay_date: "2026-04-16", federal_941_liability: 100.25 }
        ]
      }
      fields = {
        daily_liabilities: [
          { pay_date: "2026-04-16", amount: 125.25 },
          { pay_date: "2026-07-01", amount: 999.0 }
        ]
      }

      rows = described_class.new(report: report, fields: fields).send(:federal_daily_liability)

      expect(rows).to eq([
        { pay_date: "2026-04-16", month: 4, amount: 125.25 }
      ])
    end
  end
end

RSpec.describe QuarterlyComplianceOfficialForms::W1 do
  let(:report) do
    {
      meta: {
        company_name: "Cornerstone Tax Services",
        ein: "12-3456789",
        year: 2026,
        quarter: 3,
        quarter_end: "2026-09-30"
      },
      w1: {
        daily_liabilities: [],
        total_guam_withholding: 650.0
      }
    }
  end

  describe "#generate" do
    it "derives liability months from pay dates when reviewed rows omit month" do
      report = {
        meta: {
          company_name: "Cornerstone Tax Services",
          ein: "12-3456789",
          year: 2026,
          quarter: 2,
          quarter_end: "2026-06-30"
        },
        w1: {
          daily_liabilities: [],
          total_guam_withholding: 125.25
        }
      }
      fields = {
        daily_liabilities: [
          { pay_date: "2026-04-16", amount: 125.25 },
          { pay_date: "2026-07-01", amount: 999.0 }
        ],
        total_guam_withholding: 125.25
      }

      pdf = described_class.new(report: report, fields: fields).generate

      expect(pdf.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end
  end

  it "uses the official template fields for daily withholding rows" do
    form = described_class.new(report: report)

    expect(form.send(:w1_day_rect, 1, 3)).to eq(
      [ 76.874527, 516.657776, 147.1866, 528.845215 ]
    )
    expect(form.send(:w1_day_rect, 3, 25)).to eq(
      [ 401.716278, 282.752991, 471.559601, 294.00293 ]
    )
  end

  it "draws each monthly total and the quarter total" do
    fields = {
      daily_liabilities: [
        { pay_date: "2026-07-03", amount: 100.25 },
        { pay_date: "2026-07-15", amount: 49.75 },
        { pay_date: "2026-08-07", amount: 200.0 },
        { pay_date: "2026-09-25", amount: 300.0 }
      ],
      total_guam_withholding: 650.0
    }
    form = described_class.new(report: report, fields: fields)
    draws = []
    allow(form).to receive(:draw_text_box) do |_pdf, box, text, **options|
      draws << [ box, text, options ]
    end

    form.send(:draw_page, Object.new, 1)

    expect(draws).to include(
      [ described_class::MONTH_TOTAL_RECTS.fetch(1), "150.00", { size: 7, align: :right } ],
      [ described_class::MONTH_TOTAL_RECTS.fetch(2), "200.00", { size: 7, align: :right } ],
      [ described_class::MONTH_TOTAL_RECTS.fetch(3), "300.00", { size: 7, align: :right } ],
      [ described_class::QUARTER_TOTAL_RECT, "650.00", { size: 7, align: :right } ]
    )
  end

  it "derives the quarter total from edited daily liabilities when no total override is provided" do
    fields = {
      daily_liabilities: [
        { pay_date: "2026-07-03", amount: 100.0 },
        { pay_date: "2026-09-25", amount: 300.0 }
      ]
    }
    form = described_class.new(report: report, fields: fields)
    draws = []
    allow(form).to receive(:draw_text_box) do |_pdf, box, text, **options|
      draws << [ box, text, options ]
    end

    form.send(:draw_page, Object.new, 1)

    expect(draws).to include(
      [ described_class::QUARTER_TOTAL_RECT, "400.00", { size: 7, align: :right } ],
      [ described_class::TOTALS.fetch(:line1), "400.00", { size: 7, align: :right } ],
      [ described_class::TOTALS.fetch(:line3), "400.00", { size: 7, align: :right } ]
    )
  end
end

RSpec.describe QuarterlyComplianceOfficialForms::Sw2 do
  let(:company) { create(:company, ein: "12-3456789") }
  let(:department) { create(:department, company: company) }
  let(:employees) do
    12.times.map do |index|
      create(
        :employee,
        company: company,
        department: department,
        first_name: format("Worker%02d", index + 1),
        last_name: "Example",
        ssn_encrypted: format("123-45-%04d", index + 1)
      )
    end
  end
  let(:employee_rows) do
    employees.each_with_index.map do |employee, index|
      {
        employee_id: employee.id,
        name: employee.full_name,
        status: "active",
        swica_wages: 1_000 + index,
        guam_withholding: 100 + index
      }
    end
  end
  let(:report) do
    {
      meta: {
        company_name: company.name,
        ein: company.ein,
        year: 2026,
        quarter: 3,
        quarter_end: "2026-09-30"
      },
      swica: {
        employees: employee_rows,
        totals: {
          employee_count: employee_rows.length,
          total_wages: employee_rows.sum { |row| row[:swica_wages] },
          total_tax_withheld: employee_rows.sum { |row| row[:guam_withholding] }
        }
      }
    }
  end

  describe "#generate" do
    it "keeps each employee page independent when the official template has one page" do
      reader = PDF::Reader.new(StringIO.new(described_class.new(report: report).generate))

      expect(reader.page_count).to eq(2)
      expect(reader.pages.first.text).to include("Worker01 Example", "Worker11 Example")
      expect(reader.pages.first.text).not_to include("Worker12 Example")
      expect(reader.pages.second.text).to include("Worker12 Example")
      expect(reader.pages.second.text).not_to include("Worker01 Example", "Worker11 Example")
    end

    it "draws status, wages, and withholding in their labeled template columns" do
      form = described_class.new(report: report)
      draws = []
      allow(form).to receive(:employee_ssn).and_return("123-45-0001")
      allow(form).to receive(:draw_text_box) do |_pdf, box, text, **options|
        draws << [ box, text, options ]
      end

      form.send(:draw_employee_row, Object.new, employee_rows.first, 0)

      expect(draws).to include(
        [ [ 630, 399.0, 750, 416.0 ], "A", { size: 7, align: :center } ],
        [ [ 754, 399.0, 870, 416.0 ], "1000.00", { size: 7, align: :right } ],
        [ [ 872.505005, 401.498779, 975.005554, 418.998871 ], "100.00", { size: 7, align: :right } ]
      )
    end

    it "keeps the last employee withholding amount inside its official field" do
      form = described_class.new(report: report)
      draws = []
      allow(form).to receive(:employee_ssn).and_return("123-45-0011")
      allow(form).to receive(:draw_text_box) do |_pdf, box, text, **options|
        draws << [ box, text, options ]
      end

      form.send(:draw_employee_row, Object.new, employee_rows.last, 10)

      expect(draws).to include(
        [ [ 873.755005, 71.496902, 978.130615, 88.371994 ], "111.00", { size: 7, align: :right } ]
      )
    end
  end
end
