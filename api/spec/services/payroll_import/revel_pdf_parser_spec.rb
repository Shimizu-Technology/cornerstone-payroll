# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::RevelPdfParser do
  let(:rows) do
    [
      { name: "Example, Avery", regular_hours: 40.0, regular_pay: 800.0 },
      { name: "Fixture, Casey R.", regular_hours: 32.5, regular_pay: 650.0 },
      {
        name: "Boundary-Safe, Jordan",
        regular_hours: 40.0,
        regular_pay: 1_000.0,
        overtime_hours: 4.0,
        overtime_pay: 150.0
      }
    ]
  end
  let(:fixture_pdf) { build_revel_pdf(rows) }
  let(:parser) { described_class.new(fixture_pdf) }

  describe ".parse" do
    it "rejects a missing file" do
      expect { described_class.parse("/tmp/nonexistent_abc123.pdf") }
        .to raise_error(ArgumentError, /File not found/)
    end

    it "rejects a non-PDF extension" do
      file = Tempfile.new([ "revel-wrong-extension", ".txt" ])
      file.write("not a PDF")
      file.close

      expect { described_class.parse(file.path) }.to raise_error(ArgumentError, /not a PDF/)
    ensure
      file&.unlink
    end

    it "parses a deidentified, production-shaped PDF through PDF::Reader" do
      records = described_class.parse(fixture_pdf)

      expect(records.map { |record| record[:employee_name] })
        .to eq([ "Example, Avery", "Fixture, Casey R.", "Boundary-Safe, Jordan" ])
      expect(records.sum { |record| record[:total_hours] }).to eq(116.5)
      expect(records.sum { |record| record[:total_pay] }).to eq(2_600.0)
      expect(records.last).to include(
        regular_hours: 40.0,
        overtime_hours: 4.0,
        regular_pay: 1_000.0,
        overtime_pay: 150.0,
        total_hours: 44.0,
        total_pay: 1_150.0
      )
    end

    it "returns the complete downstream import shape with numeric, plausible values" do
      required_keys = %i[
        employee_name regular_hours overtime_hours regular_pay overtime_pay
        total_hours total_pay hourly_rate
      ]

      described_class.parse(fixture_pdf).each do |record|
        expect(record.keys).to include(*required_keys)
        expect(record[:total_hours]).to be_a(Numeric)
        expect(record[:total_pay]).to be_a(Numeric)
        expect(record[:total_hours]).to be_between(0, 200)
        expect(record[:total_pay]).to be >= 0
      end
    end
  end

  describe "fallback parsing" do
    it "flags fixed-column values that require the flexible parser" do
      expect(parser.send(:implausible_fixed_parse?, employee: "Fixture, Casey", total_hours: 224.41, total_pay: 224.41)).to be(true)
      expect(parser.send(:implausible_fixed_parse?, employee: "", total_hours: 40.0, total_pay: 400.0)).to be(true)
      expect(parser.send(:implausible_fixed_parse?, employee: "Example, Avery", total_hours: 0.0, total_pay: 400.0)).to be(true)
      expect(parser.send(:implausible_fixed_parse?, employee: "Example, Avery", total_hours: 80.0, total_pay: 1_200.0)).to be(false)
    end

    it "right-aligns a compressed Revel row into realistic payroll columns" do
      line = "Compressed, Rowan".ljust(40) + "- - - 24.26 - - 224.41 - - 24.26 224.41 -"
      values = parser.send(:parse_flexible_columns, line)

      expect(values).to include(
        employee: "Compressed, Rowan",
        regular_hours: 24.26,
        regular_pay: 224.41,
        total_hours: 24.26,
        total_pay: 224.41
      )
      expect(values[:total_hours]).to be < 200
    end
  end

  describe "name normalization and multiline extraction" do
    {
      "Example, Avery" => "Example, Avery",
      "Example," => "Example",
      "Fixture, Casey R." => "Fixture, Casey R.",
      "Young  Paul" => "Young Paul"
    }.each do |input, expected|
      it "normalizes #{input.inspect}" do
        expect(parser.send(:normalize_name, input)).to eq(expected)
      end
    end

    it "merges a last-name line with a following first-name payroll row" do
      data_row = revel_row(name: "Avery", regular_hours: 40, regular_pay: 800)
      lines = [ RevelPdfFixtureHelper::REVEL_HEADER, "Example,", data_row, "Totals 40.00 800.00" ]

      employee_lines = parser.send(:find_employee_lines, lines, 0)
      records = parser.send(:parse_employee_lines, employee_lines)

      expect(records.one?).to be(true)
      expect(records.first).to include(employee_name: "Example, Avery", total_hours: 40.0, total_pay: 800.0)
    end
  end

  describe "deidentified corpus regression" do
    let(:corpora) do
      [
        [
          { name: "Alpha, Ana", regular_hours: 40.0, regular_pay: 720.0 },
          { name: "Beta, Ben", regular_hours: 38.0, regular_pay: 760.0 }
        ],
        [
          { name: "Gamma, Gia", regular_hours: 40.0, regular_pay: 1_000.0, overtime_hours: 6.0, overtime_pay: 225.0 },
          { name: "Delta, Dev", regular_hours: 20.0, regular_pay: 500.0 },
          { name: "Epsilon, Eli", regular_hours: 0.0, regular_pay: 0.0, overtime_hours: 8.0, overtime_pay: 300.0 }
        ],
        [
          { name: "Zeta, Zoe", regular_hours: 80.0, regular_pay: 1_600.0 },
          { name: "Eta, Evan", regular_hours: 41.5, regular_pay: 1_037.5 }
        ]
      ]
    end

    it "parses every generated report with exact counts, totals, and no blank or outlier rows" do
      corpora.each do |corpus|
        records = described_class.parse(build_revel_pdf(corpus))

        expect(records.length).to eq(corpus.length)
        expect(records.sum { |record| record[:total_hours] })
          .to eq(corpus.sum { |row| row.fetch(:total_hours, row.fetch(:regular_hours) + row.fetch(:overtime_hours, 0.0)) })
        expect(records.sum { |record| record[:total_pay] })
          .to eq(corpus.sum { |row| row.fetch(:total_pay, row.fetch(:regular_pay) + row.fetch(:overtime_pay, 0.0)) })
        expect(records).to all(satisfy { |record| record[:employee_name].present? && record[:total_hours] <= 200 })
      end
    end
  end
end
