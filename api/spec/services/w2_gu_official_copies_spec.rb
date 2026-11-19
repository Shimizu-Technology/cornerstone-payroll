# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe W2GuOfficialCopies do
  let(:company) do
    create(:company, name: "Tumon Bakery", ein: "98-7654321", address_line1: "123 Marine Corps Dr",
      address_line2: "Suite 204", city: "Tamuning", state: "GU", zip: "96913")
  end
  let(:department) { create(:department, company: company) }
  let!(:santos) do
    create(:employee, company: company, department: department, first_name: "Maria", middle_name: "Lourdes",
      last_name: "Santos", ssn_encrypted: "123-45-4567", address_line1: "100 Chalan Santo Papa", city: "Hagåtña")
  end
  let!(:aguon) do
    create(:employee, company: company, department: department, first_name: "Jose", middle_name: nil,
      last_name: "Aguon", ssn_encrypted: "234-56-1234", address_line1: "101 Route 4", city: "Sinajana")
  end
  let!(:cruz) do
    create(:employee, company: company, department: department, first_name: "Ana", middle_name: nil,
      last_name: "Cruz", ssn_encrypted: "345-67-7890", address_line1: "7 Route 8", city: "Maite")
  end

  def row(employee, box1:, box12: [], retirement: false, tips: 0, occupations: [])
    {
      employee_id: employee.id, employee_ssn_last4: employee.ssn_last_four,
      box1_wages_tips_other_comp: box1, box2_federal_income_tax_withheld: 2_150.25,
      box3_social_security_wages: 52_000.0, box4_social_security_tax_withheld: 3_224.0,
      box5_medicare_wages_tips: 52_000.0, box6_medicare_tax_withheld: 754.0,
      box7_social_security_tips: tips, box12: box12, box13_retirement_plan: retirement,
      box14b_tipped_occupation_codes: occupations
    }
  end

  # Aggregator order is not relied on: rows arrive unsorted.
  let(:report) do
    {
      meta: { year: 2026 },
      employees: [
        row(santos, box1: 48_250.5, box12: [ { code: "D", amount: 3_749.5 } ], retirement: true),
        row(aguon, box1: 31_000.0, tips: 1_250.0, occupations: [ "101" ],
          box12: [ { code: "TP", amount: 1_250.0 }, { code: "TT", amount: 830.25 } ]),
        row(cruz, box1: 27_500.75)
      ]
    }
  end

  def render(kind:, draft:)
    PDF::Reader.new(StringIO.new(described_class.new(company: company, report: report, kind: kind, draft: draft).generate))
  end

  # Both readings of each page: Page#text keeps the template's overlapping
  # labels legible, and glyph rows (PdfBoxText) keep values a watermark would
  # make Page#text overwrite.
  def text(reader)
    reader.pages.map { |page| [ page.text, *pdf_rows(page) ].join("\n") }
  end

  describe "employee copies (B and C)" do
    let(:reader) { render(kind: "employee", draft: false) }
    let(:pages) { text(reader) }

    it "prints one double-sided sheet per employee, sorted by last name" do
      expect(reader.page_count).to eq(6)
      expect(pages.values_at(0, 2, 4).map { |page| page[/(Aguon|Cruz|Santos), \w+ · Tumon Bakery/, 1] }).to eq(%w[Aguon Cruz Santos])
      expect(pages[0]).to include("To Be Filed With Employee’s Guam Tax Return", "(See Notice to Employee on the back of Copy B.)", "employee 1 of 3")
      # Copy B's half is clipped to the top of the sheet and Copy C's to the bottom.
      expect(reader.pages[0].raw_content).to include("q 0 396.0 612.0 396.0 re W n", "q 0 0 612.0 396.0 re W n")
      expect(pages[1]).to include("Notice to Employee")
      expect(pages[1]).to include("back of Copy B)", "continued on back of Copy C")
      expect(pages.join).not_to include("Copy 1—For Guam", "Copy A")
    end

    it "shows only the last four SSN digits, never the full number" do
      expect(pdf_rows(reader.pages[0]).join("\n").scan("XXX-XX-1234").length).to eq(2)
      expect(pages[4]).to include("XXX-XX-4567")
      all = pages.join(" ")
      [ "234-56-1234", "234561234", "123-45-4567", "123454567", "345-67-7890" ].each { |ssn| expect(all).not_to include(ssn) }
    end

    it "fills the boxes from the aggregator row and leaves unmodeled boxes blank" do
      aguon_sheet = pages[0]
      expect(aguon_sheet).to include("98-7654321", "Tumon Bakery", "123 Marine Corps Dr", "Suite 204", "Tamuning, GU 96913")
      expect(aguon_sheet).to include("Jose", "Aguon", "101 Route 4", "Sinajana, GU 96910")
      expect(aguon_sheet).to include("31000.00", "2150.25", "52000.00", "3224.00", "754.00", "1250.00", "830.25", "TP", "TT", "101")

      santos_sheet = pages[4]
      expect(santos_sheet).to include("Maria L.", "48250.50", "3749.50")
      expect(pdf_rows(reader.pages[4]).join("\n").scan(/\bX\b/).length).to eq(2) # Box 13 retirement plan, on Copy B and Copy C

      cruz_sheet = pages[2]
      expect(cruz_sheet).to include("27500.75")
      expect(cruz_sheet).not_to match(/\bX\b/)
      expect(cruz_sheet).not_to include("1250.00") # Box 7 stays blank without tips
    end

    it "keeps no fillable form fields from the template" do
      reader.pages.each { |page| expect(page.attributes[:Annots]).to be_nil }
    end
  end

  describe "Copy 1 for Guam DRT" do
    let(:reader) { render(kind: "drt", draft: false) }
    let(:pages) { text(reader) }

    it "prints two employees a page with their full SSNs" do
      expect(reader.page_count).to eq(2)
      expect(pages[0]).to include("Copy 1—For Guam Department of Revenue and Taxation", "234-56-1234", "345-67-7890", "page 1 of 2")
      expect(pages[1]).to include("123-45-4567", "Santos")
      expect(pages.join).not_to include("XXX-XX")
    end

    it "clips away the unused bottom form on the last page" do
      expect(reader.pages[0].raw_content).not_to include("re W n")
      expect(reader.pages[1].raw_content).to include("q 0 396.0 612.0 396.0 re W n")
      expect(reader.pages[1].raw_content).not_to include("q 0 0 612.0 396.0 re W n")
    end
  end

  describe "where values print" do
    fields = described_class::FIELDS
    box12a_code, box12a_amount = described_class::BOX12.first
    # Values sit a little above each widget rectangle's bottom rule.
    lift = ->(rect) { [ rect[0], rect[1], rect[2], rect[3] + described_class::TEXT_LIFT ] }
    expected_boxes = lambda do |ssn:, box1:, box12a: nil|
      {
        lift.(fields[:ssn]) => ssn, lift.(fields[:ein]) => "98-7654321",
        lift.(fields[:box1]) => box1, lift.(fields[:box2]) => "2150.25", lift.(fields[:box3]) => "52000.00",
        lift.(fields[:box5]) => "52000.00", lift.(box12a_code) => box12a&.first.to_s, lift.(box12a_amount) => box12a&.last.to_s
      }
    end

    def expect_boxes(page, boxes, dy: 0)
      boxes.each do |rect, value|
        expect(text_in_box(page, shift_rect(rect, dy))).to eq(value), "expected #{value.inspect} in #{shift_rect(rect, dy).inspect}"
      end
    end

    it "puts each value inside its box on Copy B and on Copy C below it" do
      page = render(kind: "employee", draft: true).pages.first
      boxes = expected_boxes.(ssn: "XXX-XX-1234", box1: "31000.00", box12a: %w[TP 1250.00])

      expect_boxes(page, boxes)
      expect_boxes(page, boxes, dy: described_class::HALF_PAGE)
    end

    it "puts each value inside its box for both employees on a Copy 1 page" do
      page = render(kind: "drt", draft: false).pages.first

      expect_boxes(page, expected_boxes.(ssn: "234-56-1234", box1: "31000.00", box12a: %w[TP 1250.00]))
      expect_boxes(page, expected_boxes.(ssn: "345-67-7890", box1: "27500.75"), dy: described_class::HALF_PAGE)
    end
  end

  describe "values that don't fit" do
    def generate(kind: "employee", rows: report)
      described_class.new(company: company, report: rows, kind: kind, draft: true).generate
    end

    it "lists every employee and box that would be cut short instead of printing part of it" do
      santos.update_columns(first_name: "Maria", address_line1: "Lot 1234 Unit 5678 Barrigada Heights " * 20)
      cruz.update_columns(last_name: "Cruz-Santos de la Torre y Fernandez Aguon")

      expect { generate }.to raise_error(described_class::DoesNotFit) { |error|
        expect(error.problems).to eq([
          "Ana Cruz-Santos de la Torre y Fernandez Aguon: the last name is too long to fit Box e — shorten it on the employee's profile.",
          "Maria Lourdes Santos: the address is too long to fit Box f — shorten it on the employee's profile."
        ])
        expect(error.message).to start_with("These W-2GU copies can't be made until these are fixed:\n• Ana Cruz-Santos")
      }
    end

    it "names an employer whose name and address can't fit Box c" do
      company.update_columns(name: "Tumon Bay Bakery and Catering Services of the Western Pacific " * 12)

      expect { generate(kind: "drt") }.to raise_error(described_class::DoesNotFit, /employer's name and address are too long to fit Box c/)
    end

    it "prints a long value that fits by shrinking it, whole" do
      santos.update_columns(address_line1: "1234 Chalan Santo Papa Juan Pablo Dos, Unit 5B")

      reader = PDF::Reader.new(StringIO.new(generate))
      expect(text(reader)[4]).to include("1234 Chalan Santo Papa Juan Pablo Dos, Unit 5B")
    end

    it "refuses more Box 12 entries than one W-2 holds" do
      entries = %w[D AA TP TT W].map { |code| { code: code, amount: 10 } }
      rows = report.merge(employees: [ row(cruz, box1: 1_000, box12: entries) ])

      expect { generate(rows: rows) }.to raise_error(described_class::DoesNotFit, /Ana Cruz: 5 Box 12 entries, but one W-2 holds 4/)
    end

    it "refuses an employee with more tipped occupation codes than Box 14b holds" do
      rows = report.merge(employees: [ row(cruz, box1: 1_000, occupations: %w[101 202]).merge(excess_box14b_tipped_occupation_codes: true) ])

      expect { generate(rows: rows) }.to raise_error(described_class::DoesNotFit, /Ana Cruz: more than two tipped occupation codes/)
    end
  end

  describe "draft watermark" do
    it "marks every page of a draft and none of the final copies" do
      draft = text(render(kind: "employee", draft: true))
      expect(draft).to all(include("DRAFT — the 2026 W-2s are not marked ready"))

      final = text(render(kind: "drt", draft: false))
      expect(final.join).not_to include("DRAFT")
    end

    it "marks a practice copy as a draft even when the W-2s are ready" do
      copies = described_class.new(company: company, report: report, kind: "employee", draft: false, practice: true)

      pages = text(PDF::Reader.new(StringIO.new(copies.generate)))
      expect(pages).to all(include("DRAFT — a practice copy. Do not give to employees or file."))
      expect(copies.filename).to end_with("_DRAFT.pdf")
    end

    it "names drafts in the filename" do
      expect(described_class.new(company: company, report: report, kind: "drt", draft: true).filename)
        .to eq("W-2GU_2026_Tumon_Bakery_Copy1_DRT_DRAFT.pdf")
      expect(described_class.new(company: company, report: report, kind: "employee", draft: false).filename)
        .to eq("W-2GU_2026_Tumon_Bakery_Employee_Copies_B_C.pdf")
    end
  end

  it "refuses a year without an IRS template" do
    expect { described_class.new(company: company, report: report.merge(meta: { year: 2027 }), kind: "drt", draft: true) }
      .to raise_error(OfficialPdfOverlay::TemplateUnavailableError, /2026 only/)
  end

  it "refuses an unknown copy" do
    expect { described_class.new(company: company, report: report, kind: "copy_a", draft: true) }.to raise_error(ArgumentError)
  end

  it "refuses a year with no W-2 employees" do
    expect { described_class.new(company: company, report: report.merge(employees: []), kind: "employee", draft: true).generate }
      .to raise_error(ArgumentError, "No employees have 2026 W-2 wages")
  end

  it "refuses a name the form can't print instead of printing boxes" do
    cruz.update_columns(last_name: "Cruz 金")
    expect { described_class.new(company: company, report: report, kind: "employee", draft: true).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName)
  end

  it "treats copies as final only while the ready mark matches the inputs" do
    readiness = W2FilingReadiness.new(company: company, year: 2026, status: "filing_ready", ready_fingerprint: "abc")

    expect(described_class.final?(company: company, year: 2026, readiness: readiness, fingerprint: "abc")).to be(true)
    expect(described_class.final?(company: company, year: 2026, readiness: readiness, fingerprint: "changed")).to be(false)
    expect(described_class.final?(company: company, year: 2026, readiness: nil, fingerprint: "abc")).to be(false)
  end
end
