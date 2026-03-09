# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::RevelPdfParser do
  let(:raw_dir) { Rails.root.join("../data/mosa-2025/raw").to_s }

  # ── Unit helpers ───────────────────────────────────────────────────────────

  # Build a fake fixed-width PDF line with the given employee name
  # padded to COLUMNS spec (totals at typical positions)
  def build_pdf_line(name, reg_h = 40.0, reg_pay = 600.0, total_h = nil, total_pay = nil)
    total_h   ||= reg_h
    total_pay ||= reg_pay

    line = name.ljust(40)           # employee (0..39)
    line += "-".ljust(20)           # role (40..59)
    line += "-".ljust(20)           # ext_id (60..79)
    line += "-".ljust(20)           # wage (80..99)
    line += reg_h.to_s.rjust(15) + " " * 5     # regular_hours (100..119)
    line += "-".ljust(20)           # overtime_hours (120..139)
    line += "-".ljust(20)           # doubletime_hours (140..159)
    line += reg_pay.to_s.rjust(15) + " " * 5   # regular_pay (160..179)
    line += "-".ljust(20)           # overtime_pay (180..199)
    line += "-".ljust(20)           # doubletime_pay (200..219)
    line += total_h.to_s.rjust(15) + " " * 5   # total_hours (220..239)
    line += total_pay.to_s.rjust(15) + " " * 5 # total_pay (240..259)
    line += "-".ljust(20)           # fees (260..279)
    line
  end

  # ── Parser instantiation ───────────────────────────────────────────────────

  describe ".parse" do
    context "when file does not exist" do
      it "raises ArgumentError" do
        expect {
          described_class.parse("/tmp/nonexistent_abc123.pdf")
        }.to raise_error(ArgumentError, /File not found/)
      end
    end

    context "when file has wrong extension" do
      let(:txt_file) { Tempfile.new(["test", ".txt"]).tap { |f| f.write("data"); f.close } }

      it "raises ArgumentError" do
        expect {
          described_class.parse(txt_file.path)
        }.to raise_error(ArgumentError, /not a PDF/)
      end
    end
  end

  # ── Fixed column parsing ──────────────────────────────────────────────────

  describe "#parse (unit — fixed-width column logic)" do
    let(:parser) { described_class.new(File.join(raw_dir, "payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf")) }

    it "is callable via class method" do
      expect(described_class).to respond_to(:parse)
    end

    it "returns an array" do
      records = described_class.parse(File.join(raw_dir, "payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf"))
      expect(records).to be_an(Array)
    end

    it "returns hashes with required keys" do
      records = described_class.parse(File.join(raw_dir, "payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf"))
      expect(records).not_to be_empty
      required_keys = %i[employee_name regular_hours overtime_hours regular_pay overtime_pay total_hours total_pay hourly_rate]
      records.each do |r|
        required_keys.each { |k| expect(r).to have_key(k), "Missing key #{k} in #{r.inspect}" }
      end
    end

    it "parses employees with valid numeric fields" do
      records = described_class.parse(File.join(raw_dir, "payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf"))
      records.each do |r|
        expect(r[:total_hours]).to be_a(Numeric), "expected Numeric total_hours for #{r[:employee_name]}"
        expect(r[:total_pay]).to be_a(Numeric), "expected Numeric total_pay for #{r[:employee_name]}"
        expect(r[:total_hours]).to be >= 0
        expect(r[:total_pay]).to be >= 0
      end
    end

    it "does not include any record exceeding the 200h outlier threshold" do
      records = described_class.parse(File.join(raw_dir, "payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf"))
      outliers = records.select { |r| r[:total_hours].to_f > 200.0 }
      expect(outliers).to be_empty, "Unexpected outlier rows: #{outliers.map { |r| r[:employee_name] }}"
    end
  end

  # ── Fallback parser edge cases ─────────────────────────────────────────────

  describe "fallback parser (compressed-layout lines)" do
    let(:parser_instance) do
      # We need to access private methods — use send
      described_class.new(File.join(raw_dir, "payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf"))
    end

    it "detects implausible parse when total_hours > 200" do
      implausible = { employee: "Thomas, Natalie", total_hours: 224.41, total_pay: 224.41 }
      expect(parser_instance.send(:implausible_fixed_parse?, implausible)).to be true
    end

    it "detects implausible parse when employee is blank" do
      blank_emp = { employee: "", total_hours: 40.0, total_pay: 400.0 }
      expect(parser_instance.send(:implausible_fixed_parse?, blank_emp)).to be true
    end

    it "detects implausible parse when total_pay > 0 but hours = 0" do
      zero_hours = { employee: "Smith, John", total_hours: 0.0, total_pay: 400.0 }
      expect(parser_instance.send(:implausible_fixed_parse?, zero_hours)).to be true
    end

    it "considers valid parse plausible" do
      valid = { employee: "Smith, John", total_hours: 80.0, total_pay: 1200.0 }
      expect(parser_instance.send(:implausible_fixed_parse?, valid)).to be false
    end

    # Regression: PP09 Thomas, Natalie 224.41h was the last known outlier
    # After fix (threshold 240→200), the flexible parser should produce 24.26h
    it "PP09 regression: flexible parser produces realistic hours for compressed layout" do
      pp09_path = File.join(raw_dir, "payroll_2025-05-05_00-00_to_2025-05-18_23-59.pdf")
      skip "PP09 file not found" unless File.exist?(pp09_path)

      records = described_class.parse(pp09_path)
      natalie = records.find { |r| r[:employee_name] =~ /Thomas.*Natalie|Natalie.*Thomas/i }

      if natalie
        expect(natalie[:total_hours]).to be < 200.0, "Thomas, Natalie should not have outlier hours"
        expect(natalie[:total_hours]).to be_between(20.0, 40.0)
      end
    end
  end

  # ── Name normalization ─────────────────────────────────────────────────────

  describe "#normalize_name (private)" do
    let(:parser_instance) do
      described_class.new(File.join(raw_dir, "payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf"))
    end

    {
      "Belleza, Vincent"      => "Belleza, Vincent",
      "Belleza,"              => "Belleza",         # trailing comma stripped
      "Camacho, Zachary"      => "Camacho, Zachary",
      "Arthur, Juile R."      => "Arthur, Juile R.",
      "Young  Paul"           => "Paul, Young",    # no comma → reversed
    }.each do |input, expected|
      it "normalizes '#{input}' → '#{expected}'" do
        result = parser_instance.send(:normalize_name, input)
        expect(result).to eq(expected)
      end
    end
  end

  # ── Multi-line name merging ────────────────────────────────────────────────

  describe "multi-line name handling" do
    it "parses all 25+ known pay period PDFs without error" do
      pdfs = Dir.glob(File.join(raw_dir, "payroll_*.pdf"))
      expect(pdfs).not_to be_empty, "No payroll PDFs found in #{raw_dir}"

      pdfs.each do |pdf_path|
        expect {
          records = described_class.parse(pdf_path)
          expect(records).to be_an(Array), "Expected array from #{File.basename(pdf_path)}"
          expect(records.length).to be > 0, "Empty records from #{File.basename(pdf_path)}"
        }.not_to raise_error
      end
    end

    it "all employees in all PDFs have non-blank names" do
      Dir.glob(File.join(raw_dir, "payroll_*.pdf")).each do |pdf_path|
        records = described_class.parse(pdf_path)
        blank_names = records.select { |r| r[:employee_name].to_s.strip.empty? }
        expect(blank_names).to be_empty,
          "#{File.basename(pdf_path)} has #{blank_names.length} blank-name rows"
      end
    end
  end

  # ── Real-data smoke tests ─────────────────────────────────────────────────

  describe "real data smoke tests" do
    {
      "PP20 (Oct 6–19, previously missing)" =>
        ["payroll_2025-10-06_00-00_to_2025-10-19_23-59.pdf", 45..55, 28_000.0..32_000.0],
      "PP00 (Dec 30–Jan 11)" =>
        ["payroll_2024-12-30_00-00_to_2025-01-12_23-59.pdf", 38..50, 28_000.0..36_000.0],
      "PP25 (Dec 15–27)" =>
        ["payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf", 40..55, 25_000.0..36_000.0]
    }.each do |label, (filename, emp_range, pay_range)|
      context label do
        let(:pdf_path) { File.join(raw_dir, filename) }

        before { skip "File not found: #{filename}" unless File.exist?(pdf_path) }

        it "parses without error" do
          expect { described_class.parse(pdf_path) }.not_to raise_error
        end

        it "returns expected employee count (#{emp_range})" do
          records = described_class.parse(pdf_path)
          expect(records.length).to be_between(emp_range.min, emp_range.max),
            "Expected #{emp_range} employees, got #{records.length}"
        end

        it "total gross pay in expected range (#{pay_range})" do
          records = described_class.parse(pdf_path)
          total = records.sum { |r| r[:total_pay].to_f }
          expect(total).to be_between(pay_range.min, pay_range.max),
            "Total gross $#{total.round(2)} outside expected range #{pay_range}"
        end

        it "no outlier rows (>200h)" do
          records = described_class.parse(pdf_path)
          outliers = records.select { |r| r[:total_hours].to_f > 200.0 }
          expect(outliers).to be_empty
        end
      end
    end
  end
end
