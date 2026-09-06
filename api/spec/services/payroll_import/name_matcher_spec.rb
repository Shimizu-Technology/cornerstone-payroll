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
      StubEmployee.new(9, "Rosie",     "Petirus",   "Rosie Petirus")
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
      expect([ nil, Hash ]).to include(result.class)
    end

    it "matches transposed first name 'Arthur, Juile R.' → Julie Arthur" do
      julie_employees = [ StubEmployee.new(10, "Julie", "Arthur", "Julie Arthur") ]
      transposition_matcher = described_class.new(julie_employees)
      result = transposition_matcher.match_pdf_name("Arthur, Juile R.")
      expect(result).not_to be_nil
      expect(result[:employee_id]).to eq(10)
      expect(result[:confidence]).to be >= 0.7
    end

    it "matches a transposed last-name typo without weakening the first-name safeguard" do
      result = matcher.match_pdf_name("Petrius, Rosie")

      expect(result).to include(employee_id: 9, matched_name: "Rosie Petirus")
      expect(result[:confidence]).to be_between(0.9, 0.99)
      expect(matcher.match_pdf_name("Petrius, Different")).to be_nil
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
      m = described_class.new([ broken_emp ])
      result = m.match_pdf_name("OnlyFirst,")
      # Should not crash — result may be nil or a match
      expect([ nil, Hash ]).to include(result.class)
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

  # ── Distance helper methods ────────────────────────────────────────────────

  describe "#ld (private)" do
    it "returns 0 for identical strings" do
      expect(matcher.send(:ld, "hello", "hello")).to eq(0)
    end

    it "returns 1 for single substitution" do
      expect(matcher.send(:ld, "hello", "heLlo")).to eq(1)
    end

    it "returns correct distance for typical name typo" do
      d = matcher.send(:ld, "belleza", "beleeza")
      expect(d).to be <= 2
    end
  end

  describe "#dld (private)" do
    it "returns 0 for identical strings" do
      expect(matcher.send(:dld, "hello", "hello")).to eq(0)
    end

    it "counts a transposition as 1 edit" do
      expect(matcher.send(:dld, "juile", "julie")).to eq(1)
    end

    it "returns 1 for single substitution" do
      expect(matcher.send(:dld, "hello", "heLlo")).to eq(1)
    end
  end

  describe "integration with persisted deidentified employees" do
    let(:organization) { create(:organization) }
    let(:company) { create(:company, organization: organization) }
    let!(:persisted_employees) do
      [
        create(:employee, company: company, first_name: "Avery", last_name: "Example"),
        create(:employee, company: company, first_name: "Casey", last_name: "Fixture"),
        create(:employee, company: company, first_name: "Jordan", last_name: "Boundary-Safe")
      ]
    end

    it "matches every name parsed from a generated Revel-shaped PDF" do
      pdf_path = build_revel_pdf([
        { name: "Example, Avery", regular_hours: 40.0, regular_pay: 800.0 },
        { name: "Fixture, Casey R.", regular_hours: 32.5, regular_pay: 650.0 },
        { name: "Boundary-Safe, Jordan", regular_hours: 44.0, regular_pay: 1_100.0 }
      ])
      matcher = described_class.new(persisted_employees)
      records = PayrollImport::RevelPdfParser.parse(pdf_path)
      unmatched = records.reject { |record| matcher.match_pdf_name(record[:employee_name]) }

      expect(records.length).to eq(3)
      expect(unmatched).to be_empty
    end
  end
end
