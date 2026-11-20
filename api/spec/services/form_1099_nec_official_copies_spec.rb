# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe Form1099NecOfficialCopies do
  let(:company) do
    create(:company, name: "Tumon Bakery", ein: "98-7654321", address_line1: "123 Marine Corps Dr",
      address_line2: "Suite 204", city: "Tamuning", state: "GU", zip: "96913", phone: "671-555-0100")
  end
  let(:department) { create(:department, company: company) }
  let!(:santos) do
    create(:employee, :contractor, company: company, department: department, first_name: "Maria", middle_name: "Lourdes",
      last_name: "Santos", ssn_encrypted: "123-45-4567", address_line1: "100 Chalan Santo Papa", address_line2: "Apt 3B",
      city: "Hagatna", state: "GU", zip: "96910")
  end
  let!(:roofing) do
    create(:employee, :business_contractor, company: company, department: department, first_name: "Pedro", last_name: "Reyes",
      business_name: "Island Roofing LLC", contractor_ein: "66-1234567", ssn_encrypted: nil,
      address_line1: "PO Box 8800", address_line2: nil, city: "Tamuning", state: "GU", zip: "96931")
  end
  let!(:aguon) do
    create(:employee, :contractor, company: company, department: department, first_name: "Jose", middle_name: nil,
      last_name: "Aguon", business_name: "Aguon Electric", ssn_encrypted: "234-56-1234", address_line1: "101 Route 4",
      city: "Sinajana", state: "GU", zip: "96910")
  end

  def row(employee, total, withheld: 0)
    { employee_id: employee.id, name: employee.full_name, total_compensation: total, federal_withheld: withheld, non_employee_check_ids: [] }
  end

  # Aggregator order is not relied on; an unlinked one-off payee never prints.
  let(:report) do
    {
      meta: { year: 2026, filing_threshold: 2_000.0 },
      reportable_contractors: [
        row(santos, 4_820.5),
        { employee_id: nil, payee_key: "non_employee_check:9", name: "Unlinked Payee", total_compensation: 3_000.0, federal_withheld: 0 },
        row(roofing, 12_000.0),
        row(aguon, 2_350.75)
      ]
    }
  end

  def render(kind:, draft:, practice: false)
    pdf = described_class.new(company: company, report: report, kind: kind, draft: draft, practice: practice).generate
    if ENV["FORM_1099_SAMPLE_DIR"]
      File.binwrite(File.join(ENV["FORM_1099_SAMPLE_DIR"], "#{kind}#{'_draft' if draft}#{'_practice' if practice}.pdf"), pdf)
    end
    PDF::Reader.new(StringIO.new(pdf))
  end

  def text(reader)
    reader.pages.map { |page| [ page.text, *pdf_rows(page) ].join("\n") }
  end

  describe "recipient copies (Copy B)" do
    let(:reader) { render(kind: "recipient", draft: false) }
    let(:pages) { text(reader) }

    it "prints one double-sided sheet per contractor, sorted by the name the form shows" do
      expect(reader.page_count).to eq(6)
      expect(pages.values_at(0, 2, 4).map { |page| page[/(Aguon, Jose|Island Roofing LLC|Santos, Maria) · Tumon Bakery/, 1] })
        .to eq([ "Aguon, Jose", "Island Roofing LLC", "Santos, Maria" ])
      expect(pages[0]).to include("Copy B", "For Recipient", "contractor 1 of 3")
      expect(pages.values_at(1, 3, 5)).to all(include("Instructions for Recipient"))
      expect(pages.join).not_to include("Copy 1", "Copy A", "Copy 2", "Unlinked Payee")
    end

    it "truncates the payee's TIN and never the payer's" do
      expect(pages[0]).to include("***-**-1234", "98-7654321")
      expect(pages[2]).to include("**-***4567")
      expect(pages[4]).to include("***-**-4567")
      all = pages.join(" ")
      [ "234-56-1234", "234561234", "66-1234567", "661234567", "123-45-4567", "123454567" ].each { |tin| expect(all).not_to include(tin) }
    end

    it "fills the payer and recipient blocks and Box 1a, and the calendar year" do
      aguon_sheet = pages[0]
      expect(aguon_sheet).to include("Tumon Bakery", "123 Marine Corps Dr", "Suite 204", "Tamuning", "671-555-0100", "96913", "2026")
      expect(aguon_sheet).to include("Jose Aguon", "Aguon Electric", "101 Route 4", "Sinajana", "96910", "2350.75")
      expect(pages[2]).to include("Island Roofing LLC", "PO Box 8800", "12000.00")
      expect(pages[2]).not_to include("Pedro Reyes")
      expect(pages[4]).to include("Maria Lourdes Santos", "100 Chalan Santo Papa", "Apt 3B", "4820.50")
    end

    it "keeps no fillable form fields from the template" do
      reader.pages.each { |page| expect(page.attributes[:Annots]).to be_nil }
    end
  end

  describe "payer record" do
    let(:reader) { render(kind: "payer", draft: false) }
    let(:pages) { text(reader) }

    it "prints one form a page on the Copy 1 page with full TINs, labelled as the payer's record" do
      expect(reader.page_count).to eq(3)
      expect(pages[0]).to include("Copy 1", "Payer's record", "Keep with your filing records", "form 1 of 3", "234-56-1234")
      expect(pages[1]).to include("66-1234567", "Island Roofing LLC")
      expect(pages[2]).to include("123-45-4567", "Santos")
      expect(pages.join).not_to include("***-**", "**-***", "Instructions for Recipient")
    end
  end

  describe "where values print" do
    fields = described_class::FIELDS
    lift = ->(rect, by = described_class::TEXT_LIFT) { [ rect[0], rect[1], rect[2], rect[3] + by ] }

    def expect_boxes(page, boxes)
      boxes.each do |rect, value|
        expect(text_in_box(page, rect)).to eq(value), "expected #{value.inspect} in #{rect.inspect}"
      end
    end

    it "puts each value inside its box on Copy B" do
      page = render(kind: "recipient", draft: true).pages.first

      expect_boxes(page, {
        lift.(fields[:calendar_year], 0) => "2026",
        lift.(fields[:payer_name], 0) => "Tumon Bakery",
        lift.(fields[:payer_street]) => "123 Marine Corps Dr",
        lift.(fields[:payer_room]) => "Suite 204",
        lift.(fields[:payer_city]) => "Tamuning",
        lift.(fields[:payer_phone]) => "671-555-0100",
        lift.(fields[:payer_state]) => "GU",
        lift.(fields[:payer_zip]) => "96913",
        lift.(fields[:payer_tin], 0) => "98-7654321",
        lift.(fields[:recipient_tin], 0) => "***-**-1234",
        lift.(fields[:recipient_name], 0) => "Jose Aguon\nAguon Electric",
        lift.(fields[:recipient_street]) => "101 Route 4",
        lift.(fields[:recipient_city]) => "Sinajana",
        lift.(fields[:recipient_state]) => "GU",
        lift.(fields[:recipient_zip]) => "96910",
        lift.(fields[:box1a]) => "2350.75",
        lift.(fields[:account_number], 0) => Form1099Pub1220Generator.account_number(aguon)
      })
      # No withholding: Box 4 stays blank.
      expect(text_in_box(page, lift.(fields[:box4]))).to eq("")
    end

    it "prints withholding in Box 4 and the e-file's account number, at any amount" do
      report[:reportable_contractors] = [ row(aguon, 500, withheld: 50) ]
      page = render(kind: "recipient", draft: false).pages.first

      expect(Form1099Pub1220Generator.account_number(aguon)).to eq("C#{aguon.id.to_s.rjust(6, '0')}")
      expect_boxes(page, { lift.(fields[:box1a]) => "500.00", lift.(fields[:box4]) => "50.00",
                           lift.(fields[:account_number], 0) => "C#{aguon.id.to_s.rjust(6, '0')}" })
    end

    it "puts the full TIN in the recipient's TIN box on the payer record" do
      page = render(kind: "payer", draft: false).pages[1]

      expect_boxes(page, { lift.(fields[:recipient_tin], 0) => "66-1234567", lift.(fields[:box1a]) => "12000.00",
                           lift.(fields[:recipient_name], 0) => "Island Roofing LLC" })
    end
  end

  describe "values that don't fit" do
    def generate(kind: "recipient", rows: report)
      described_class.new(company: company, report: rows, kind: kind, draft: true).generate
    end

    it "lists every payee and box that would be cut short instead of printing part of it" do
      santos.update_columns(address_line1: "Lot 1234 Unit 5678 Barrigada Heights " * 8)
      aguon.update_columns(last_name: "Aguon-Santos de la Torre y Fernandez Cruz " * 8)

      expect { generate }.to raise_error(described_class::DoesNotFit) { |error|
        expect(error.problems).to contain_exactly(
          a_string_starting_with("Jose Aguon-Santos de la Torre").and(ending_with("the name is too long to fit the recipient's name box — shorten it on the contractor's record.")),
          "Maria Lourdes Santos: the street address is too long to fit the recipient's address box — shorten it on the contractor's record."
        )
        expect(error.message).to start_with("These 1099-NEC copies can't be made until these are fixed:")
      }
    end

    it "names a payer whose name won't fit" do
      company.update_columns(name: "Tumon Bay Bakery and Catering Services of the Western Pacific " * 6)

      expect { generate(kind: "payer") }.to raise_error(described_class::DoesNotFit, /client's name is too long to fit the payer's name box/)
    end

    it "moves a unit that won't fit its narrow box onto the street line" do
      santos.update_columns(address_line2: "Building 4, Unit 12")

      page = PDF::Reader.new(StringIO.new(generate)).pages[4]
      rect = described_class::FIELDS[:recipient_street]
      expect(text_in_box(page, [ rect[0], rect[1], rect[2], rect[3] + described_class::TEXT_LIFT ])).to eq("100 Chalan Santo Papa, Building 4, Unit 12")
    end

    it "refuses a name the form can't print instead of printing boxes" do
      aguon.update_columns(last_name: "Aguon 金")

      expect { generate }.to raise_error(described_class::DoesNotFit, /Jose Aguon 金: Contractor "Jose Aguon 金" has characters/)
    end
  end

  describe "draft watermark" do
    it "marks every page of a draft and none of the final copies" do
      expect(text(render(kind: "recipient", draft: true))).to all(include("DRAFT — the 2026 1099s are not marked ready"))
      expect(text(render(kind: "payer", draft: false)).join).not_to include("DRAFT")
    end

    it "marks a practice copy as a draft even when the 1099s are ready" do
      copies = described_class.new(company: company, report: report, kind: "recipient", draft: false, practice: true)

      expect(text(PDF::Reader.new(StringIO.new(copies.generate)))).to all(include("DRAFT — a practice copy. Do not give to contractors or file."))
      expect(copies.filename).to eq("1099-NEC_2026_Tumon_Bakery_Recipient_Copies_B_DRAFT.pdf")
    end

    it "names the payer record" do
      expect(described_class.new(company: company, report: report, kind: "payer", draft: false).filename).to eq("1099-NEC_2026_Tumon_Bakery_Payer_Record.pdf")
    end
  end

  it "truncates TINs the way the IRS allows on recipient statements" do
    expect(described_class.truncated_tin({ type: "SSN", digits: "123454567" })).to eq("***-**-4567")
    expect(described_class.truncated_tin({ type: "EIN", digits: "661234567" })).to eq("**-***4567")
    expect(described_class.truncated_tin(nil)).to be_nil
  end

  it "refuses a year without an IRS template" do
    expect { described_class.new(company: company, report: report.merge(meta: { year: 2027 }), kind: "payer", draft: true) }
      .to raise_error(OfficialPdfOverlay::TemplateUnavailableError, /2026 only/)
  end

  it "refuses an unknown copy and a year with no 1099 payees" do
    expect { described_class.new(company: company, report: report, kind: "copy_a", draft: true) }.to raise_error(ArgumentError)
    rows = report.merge(reportable_contractors: [ report[:reportable_contractors][1] ])
    expect { described_class.new(company: company, report: rows, kind: "recipient", draft: true).generate }
      .to raise_error(ArgumentError, "No contractor gets a 2026 1099-NEC")
  end
end
