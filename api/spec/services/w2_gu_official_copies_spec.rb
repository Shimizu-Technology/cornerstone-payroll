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

  def text(reader)
    reader.pages.map(&:text)
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
      expect(pages[0].scan("XXX-XX-1234").length).to eq(2)
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
      expect(santos_sheet.scan(/\bX\b/).length).to eq(2) # Box 13 retirement plan, on Copy B and Copy C

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

  describe "draft watermark" do
    it "marks every page of a draft and none of the final copies" do
      draft = text(render(kind: "employee", draft: true))
      expect(draft).to all(include("DRAFT — the 2026 W-2s are not marked ready"))

      final = text(render(kind: "drt", draft: false))
      expect(final.join).not_to include("DRAFT")
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
