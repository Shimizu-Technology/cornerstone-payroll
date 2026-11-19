# frozen_string_literal: true

require "rails_helper"

RSpec.describe Efw2W2GuGenerator do
  let(:company) { create(:company, ein: "66-1234567", establishment_number: "A001", filing_contact_name: "Employer Contact", phone: "6715554321", email: "employer@example.com") }
  let(:employee) { create(:employee, company: company, first_name: "José!", middle_name: "A.", last_name: "O'Neil", name_suffix: "Jr.", ssn_encrypted: "123-45-6789", address_line1: "123 Main St", city: "Hagatna", state: "GU", zip: "96910-1234") }
  let(:submitter) { FilingSubmitter.create!(organization: company.organization, ein: "66-7654321", name: "Practice", address_line1: "1 Main", city: "Hagatna", state: "GU", zip: "96910", contact_name: "Dafne", contact_phone: "6715551234", contact_email: "filing@example.com", bso_user_id: "ABCDEFGH") }
  let(:row) do
    described_class::BOXES.zip([ 200_000, 1234.56, 184_400, 11_439, 200_000, 2900, 100 ]).to_h.merge(employee_id: employee.id,
      box12: [ { code: "D", amount: 100 }, { code: "AA", amount: 50 }, { code: "TA", amount: 20 }, { code: "TP", amount: 30 }, { code: "TT", amount: 40 } ],
      box13_retirement_plan: true, box14b_tipped_occupation_codes: [ "101", "102" ])
  end
  let(:report) { { meta: { year: 2026 }, employees: [ row ], totals: row.slice(*described_class::BOXES).merge(box12_code_d_total: 100, box12_code_aa_total: 50, box12_code_tp_total: 30, box12_code_tt_total: 40) } }
  subject(:generator) { described_class.new(company: company, year: 2026, submitter: submitter, report: report) }

  it "preserves Vietnamese and other Latin letters" do
    { "Nguyễn Văn Trần" => "NGUYEN VAN TRAN", "Huỳnh" => "HUYNH", "Phạm" => "PHAM", "Đặng" => "DANG", "Phở Saigon" => "PHO SAIGON", "Ma’lia" => "MA'LIA", "Ñaña" => "NANA", "Åguon" => "AGUON" }.each do |input, expected|
      expect(Efw2Formatting.clean(input)).to eq(expected)
    end
  end

  it "reports unsupported letters with the employee ID and field" do
    employee.update_columns(first_name: "李")
    expect(generator.structured_problems).to include(hash_including(employee_id: employee.id, message: /first name contains letters/))
  end

  it "leaves tip judgments to warnings and writes only the first two codes" do
    row[:excess_box14b_tipped_occupation_codes] = true
    row[:box14b_tipped_occupation_codes] = %w[101 102 103]
    expect(generator.problems).to be_empty
    expect(field(generator.generate.split("\r\n"), "RW", 490, 495)).to eq("101102")
    row[:box14b_tipped_occupation_codes] = %w[101 102 000]
    expect(field(generator.generate.split("\r\n"), "RW", 490, 495)).to eq("000101")
    row[:box14b_tipped_occupation_codes] = []
    expect(generator.problems).to be_empty
  end

  it "does not treat blank SSNs as duplicates and names actual duplicates" do
    other = create(:employee, company: company, first_name: employee.first_name, last_name: employee.last_name, ssn_encrypted: employee.ssn_encrypted)
    report[:employees] << row.merge(employee_id: other.id)
    expect(generator.structured_problems.select { |problem| problem[:message].include?("duplicate SSN") }.pluck(:employee_id)).to contain_exactly(employee.id, other.id)
    [ employee, other ].each { |worker| worker.update_columns(ssn_encrypted: nil) }
    fresh = described_class.new(company: company, year: 2026, submitter: submitter, report: report)
    expect(fresh.problems.join).not_to include("duplicate SSN")
  end

  # Independent positional reader: one-based inclusive fields, no generator map.
  def field(records, type, first, last)
    records.find { |r| r[0, 2] == type }.byteslice(first - 1, last - first + 1)
  end

  it "matches literal 512-byte golden records transcribed from the SSA v4 tables" do
    company.update!(name: "Island Bakery", address_line1: "2 Palm St", address_line2: nil, city: "Tamuning", state: "GU", zip: "96913")
    expected = Rails.root.join("spec/fixtures/efw2_2026_golden.txt").read.lines(chomp: true)
    expect(expected.map(&:bytesize)).to eq([ 512 ] * 7)
    expect(generator.generate.split("\r\n")).to eq(expected)
  end

  it "normalizes apostrophes before transliterating employer and employee names" do
    company.update!(filing_contact_name: "Ma’lia ‘Cruzʼ")
    employee.update!(first_name: "Ma’lia")
    records = generator.generate.split("\r\n")
    expect(field(records, "RE", 222, 248).strip).to eq("MA'LIA 'CRUZ'")
    expect(field(records, "RW", 12, 26).strip).to eq("MA'LIA")
  end

  it "returns named box problems without raising or exposing identifiers" do
    row[:box2_federal_income_tax_withheld] = -1
    expect(generator.problems).to include("José! A. O'Neil JR: Box 2 is negative")
    expect(generator.problems.join).not_to include(employee.id.to_s + ":", "123456789")
  end

  it "checks the three SSA relational edits and omits occupation codes without TP" do
    row[:box3_social_security_wages] = 0
    row[:box7_social_security_tips] = 0
    row[:box5_medicare_wages_tips] = 0
    expect(generator.problems.join).to include("Box 4", "Box 6")
    row[:box3_social_security_wages] = 100
    expect(generator.problems.join).to include("Box 5 Medicare wages must")
    row[:box5_medicare_wages_tips] = 100
    row[:box12].reject! { |entry| entry[:code] == "TP" }
    report[:totals] = row.slice(*described_class::BOXES)
    expect(field(generator.generate.split("\r\n"), "RW", 490, 495)).to eq(" " * 6)
  end

  it "writes ASCII 512-byte records, CRLF, Guam jurisdiction, zero federal fields and numeric totals" do
    file = generator.generate
    records = file.split("\r\n")
    expect(file.end_with?("\r\n")).to be true
    expect(records.map(&:bytesize)).to eq([ 512 ] * 7)
    expect(records.map { |r| r[0, 2] }).to eq(%w[RA RE RW RO RT RU RF])
    expect(file.ascii_only?).to be true
    expect(field(records, "RA", 12, 19)).to eq("ABCDEFGH")
    expect(field(records, "RA", 36, 37)).to eq("98")
    expect(field(records, "RE", 26, 30)).to eq("0A001")
    expect(field(records, "RE", 222, 248).strip).to eq("EMPLOYER CONTACT")
    expect(field(records, "RE", 249, 263).strip).to eq("6715554321")
    expect(field(records, "RE", 279, 318).strip).to eq("employer@example.com")
    expect(field(records, "RE", 174, 174)).to eq("N")
    expect(field(records, "RE", 219, 220)).to eq("RG")
    expect(field(records, "RE", 319, 328)).to eq(" " * 10)
    expect(field(records, "RW", 188, 209)).to eq("0" * 22)
    expect(field(records, "RO", 363, 373)).to eq("00020000000")
    expect(field(records, "RO", 374, 384)).to eq("00000123456")
    expect(field(records, "RU", 460, 474)).to eq("000000020000000")
    expect(field(records, "RU", 475, 489)).to eq("000000000123456")
    expect(field(records, "RT", 40, 54).to_i).to eq(18_440_000)
    expect(field(records, "RW", 12, 26).strip).to eq("JOSE")
    expect(field(records, "RW", 42, 61).strip).to eq("O'NEIL")
    expect(field(records, "RW", 62, 65)).to eq("JR  ")
    expect(field(records, "RW", 488, 488)).to eq("1")
    expect(field(records, "RW", 490, 495)).to eq("101102")
    expect(field(records, "RW", 287, 297).to_i).to eq(10_000)
    expect(field(records, "RW", 441, 451).to_i).to eq(5000)
    expect(field(records, "RO", 221, 253)).to eq("000000020000000000300000000004000")
    expect(field(records, "RU", 295, 309).to_i).to eq(2000)
    expect(field(records, "RU", 310, 324).to_i).to eq(3000)
    expect(field(records, "RU", 325, 339).to_i).to eq(4000)
    expect(field(records, "RF", 8, 16)).to eq("000000001")
  end

  it "rejects totals which disagree with the aggregator" do
    report[:totals][:box1_wages_tips_other_comp] += 1
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /Aggregator total mismatch/)
  end

  it "rejects wages beyond the Social Security base rather than recomputing wages" do
    row[:box7_social_security_tips] = 101
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /wage base/)
  end

  it "returns a list of missing identities without returning a partial file" do
    employee.update_columns(ssn_encrypted: nil, city: nil)
    expect { generator.generate }.to raise_error(described_class::InvalidFile) { |e| expect(e.problems.length).to be >= 2 }
  end

  it "rejects negative and overflowing monetary fields" do
    row[:box1_wages_tips_other_comp] = -1
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /negative/)
    row[:box1_wages_tips_other_comp] = 1_000_000_000
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /exceeds/)
  end

  it "rejects missing submitter, unsupported codes, invalid SSNs and invalid address" do
    row[:box12] << { code: "ZZ", amount: 1 }
    employee.update_columns(ssn_encrypted: "666-12-1234", state: "ZZ")
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /valid SSN.*state.*unsupported/)
    expect { described_class.new(company: company, year: 2026, submitter: nil, report: report).generate }.to raise_error(described_class::InvalidFile, /submitter profile/)
  end
  it "uses actual aggregated wages, including the annual Social Security cap" do
    period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 14), pay_date: Date.new(2026, 1, 18))
    create(:payroll_item, company: company, employee: employee, pay_period: period,
      gross_pay: 200_000, fit_taxable_wages: 200_000, social_security_taxable_wages: 200_000,
      social_security_taxable_tips: 0, medicare_taxable_wages: 200_000,
      social_security_tax: 11_439, medicare_tax: 2900, cash_tips_reported: 0, qualified_overtime_compensation: 0)
    file = described_class.new(company: company, year: 2026, submitter: submitter).generate
    records = file.split("\r\n")
    expect(field(records, "RW", 210, 220).to_i).to eq(18_450_000)
    expect(field(records, "RO", 363, 373).to_i).to eq(20_000_000)
  end

  it "rejects Social Security tax above Version 4's maximum" do
    row[:box4_social_security_tax_withheld] = 11_439.01
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /11,439/)
  end
  it "rejects malformed required employer and submitter email fields" do
    company.update_columns(email: "filing@example..com")
    submitter.update_columns(contact_email: "filing.@example.com")
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /Submitter contact email.*Employer contact email/)
  end
end
