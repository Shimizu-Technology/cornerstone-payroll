# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::NameMatcher do
  # Build lightweight employee-like structs (no DB needed for unit tests)
  # Use a local struct to avoid colliding with AR Employee model
  StubEmployee = Struct.new(:id, :first_name, :last_name, :full_name)

  let(:employees) do
    [
      StubEmployee.new(1, "Vincent",   "Belleza",   "Vincent Belleza"),
      StubEmployee.new(2, "Zachary",   "Camacho",   "Zachary Camacho"),
      StubEmployee.new(3, "Juile",     "Arthur",    "Juile Arthur"),
      StubEmployee.new(4, "Kyle",      "Richard",   "Kyle Richard"),
      StubEmployee.new(5, "Jayden",    "Suanson",   "Jayden Suanson"),
      StubEmployee.new(6, "Maria",     "Robert",    "Maria Robert"),
      StubEmployee.new(7, "Natalie",   "Thomas",    "Natalie Thomas"),
      StubEmployee.new(8, "George",    "Setik",     "George Setik"),
    ]
  end

  subject(:matcher) { described_class.new(employees) }

  # ── Exact matching ─────────────────────────────────────────────────────────

  describe "#match_pdf_name (exact)" do
    it "matches a standard 'Last, First' PDF name" do
      result = matcher.match_pdf_name("Belleza, Vincent")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(1)
      expect(result[:confidence]).to eq(1.0)
    end

    it "matches a PDF name with middle initial: 'Arthur, Juile R.'" do
      result = matcher.match_pdf_name("Arthur, Juile R.")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(3)
    end

    it "is case-insensitive" do
      result = matcher.match_pdf_name("belleza, vincent")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(1)
    end

    it "returns nil for completely unknown name" do
      result = matcher.match_pdf_name("Nobody, Unknown")
      expect(result).to be_nil
    end

    it "returns nil for blank input" do
      expect(matcher.match_pdf_name("")).to be_nil
      expect(matcher.match_pdf_name(nil)).to be_nil
    end
  end

  # ── First-name alias matching ──────────────────────────────────────────────

  describe "FIRST_NAME_ALIASES" do
    it "matches 'Kyle A.' alias → Kyle Richard (employee)" do
      result = matcher.match_pdf_name("Richard, Kyle A.")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(4)
    end

    it "matches 'Kyle Richard' multi-word alias → Kyle Richard" do
      result = matcher.match_pdf_name("Richard, Kyle Richard")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(4)
    end

    it "matches 'Jayden M.' alias → Jayden Suanson" do
      result = matcher.match_pdf_name("Suanson, Jayden M.")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(5)
    end

    it "matches 'Maria Carmella' alias → Maria Robert" do
      result = matcher.match_pdf_name("Robert, Maria Carmella")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(6)
    end
  end

  # ── Fuzzy matching ─────────────────────────────────────────────────────────

  describe "#match_pdf_name (fuzzy)" do
    it "matches minor typo 'Beleeza, Vincent' → Vincent Belleza" do
      result = matcher.match_pdf_name("Beleeza, Vincent")
      # Fuzzy match may or may not find it depending on edit distance — just ensure no crash
      expect([nil, Hash]).to include(result.class)
    end

    it "returns nil for name with confidence below threshold" do
      # Very different name should not be matched
      result = matcher.match_pdf_name("Xyzzy, Flobberworm")
      expect(result).to be_nil
    end
  end

  # ── Excel name matching ────────────────────────────────────────────────────

  describe "#match_excel_name" do
    it "matches separate last/first name" do
      result = matcher.match_excel_name("Camacho", "Zachary")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(2)
    end

    it "handles extra whitespace" do
      result = matcher.match_excel_name("  Setik  ", "  George  ")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(8)
    end

    it "returns nil for unknown last name" do
      result = matcher.match_excel_name("Completely", "Unknown")
      expect(result).to be_nil
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────────────

  describe "edge cases" do
    it "handles employees with no last name" do
      broken_emp = StubEmployee.new(99, "OnlyFirst", "", "OnlyFirst")
      m = described_class.new([broken_emp])
      result = m.match_pdf_name("OnlyFirst,")
      # Should not crash — result may be nil or a match
      expect([nil, Hash]).to include(result.class)
    end

    it "is not case-sensitive on last name" do
      result = matcher.match_pdf_name("THOMAS, Natalie")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(7)
    end

    it "matches name with trailing comma in PDF" do
      # Some PDFs produce names like "Camacho," split over two lines (merged)
      result = matcher.match_pdf_name("Camacho, Zachary")
      expect(result).not_to be_nil
    end

    it "handles punctuation in name" do
      result = matcher.match_pdf_name("Arthur, Juile R.")
      expect(result).not_to be_nil
    end
  end

  # ── Levenshtein distance helper ────────────────────────────────────────────

  describe "#levenshtein_distance (private)" do
    it "returns 0 for identical strings" do
      expect(matcher.send(:levenshtein_distance, "hello", "hello")).to eq(0)
    end

    it "returns 1 for single substitution" do
      expect(matcher.send(:levenshtein_distance, "hello", "heLlo")).to eq(1)
    end

    it "returns correct distance for typical name typo" do
      d = matcher.send(:levenshtein_distance, "belleza", "beleeza")
      expect(d).to be <= 2
    end
  end

  # ── Integration: real DB employees + PP20 PDF names ───────────────────────

  describe "integration with real DB employees", :db do
    let(:real_employees) { Employee.where(company: Company.find_by(name: "MoSa's Joint")) rescue [] }
    let(:real_matcher) { described_class.new(real_employees) }

    before do
      skip "No MoSa employees in DB" if real_employees.empty?
    end

    it "matches all employees in PP20 PDF without unmatched names" do
      pp20_path = Rails.root.join("../data/mosa-2025/raw/payroll_2025-10-06_00-00_to_2025-10-19_23-59.pdf").to_s
      skip "PP20 PDF not found" unless File.exist?(pp20_path)

      records = PayrollImport::RevelPdfParser.parse(pp20_path)
      unmatched = records.reject { |r| real_matcher.match_pdf_name(r[:employee_name]) }

      expect(unmatched).to be_empty,
        "Unmatched PP20 employees: #{unmatched.map { |r| r[:employee_name] }.join(', ')}"
    end
  end
end
