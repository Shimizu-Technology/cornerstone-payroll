# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form1099Pub1220Generator do
  let(:company) { create(:company, name: "Payer", ein: "66-1234567", address_line1: "2 Main", address_line2: nil, city: "Hagatna", state: "GU", zip: "96910", phone: "6715554321") }
  let(:person) { create(:employee, company: company, first_name: "Jane", last_name: "Doe", middle_name: nil, ssn_encrypted: "123-45-6789", address_line1: "3 Main", address_line2: nil, city: "Hagatna", state: "GU", zip: "96910") }
  let(:submitter) { FilingSubmitter.create!(organization: company.organization, ein: "66-7654321", name: "Practice", address_line1: "1 Main", city: "Hagatna", state: "GU", zip: "96910", contact_name: "Dafne", contact_phone: "6715551234", contact_email: "filing@example.com", tcc: "ABCDE") }
  let(:row) { { employee_id: person.id, name: "Jane Doe", tin_type: "SSN", total_compensation: 2345.67, federal_withheld: 12.34 } }
  let(:report) { { reportable_contractors: [ row ], totals: { reportable_federal_withheld: 12.34, reportable_compensation: 2345.67 } } }
  subject(:generator) { described_class.new(company: company, year: 2026, submitter: submitter, draft: true, report: report) }

  it "matches independent literal 750-byte golden records including delimiters" do
    expect(generator.generate.b).to eq(File.binread(Rails.root.join("spec/fixtures/pub1220_2026_golden.txt")))
  end

  it "removes transmitter punctuation while preserving email case" do
    submitter.name = "Practice, Inc."
    submitter.address_line1 = "1 Main #2"
    t = generator.generate[0, 750]
    expect(t[29, 40].strip).to eq("PRACTICE INC")
    expect(t[189, 40].strip).to eq("1 MAIN 2")
    expect(t[358, 50].strip).to eq("filing@example.com")
  end

  it "allows a missing TCC only in test files" do
    submitter.tcc = nil
    expect(generator.generate[15, 5]).to eq("TEST0")
    final = described_class.new(company: company, year: 2026, submitter: submitter, draft: false, report: report)
    expect { final.generate }.to raise_error(described_class::InvalidFile, /transmitter control code/)
    submitter.tcc = "ABCDE"
    expect(final.generate[27]).to eq(" ")
  end

  it "blocks unidentified payees with a named problem" do
    row[:employee_id] = nil
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /Jane Doe: missing TIN and address/)
  end

  it "refuses missing addresses, negative amounts, overflow and non-ASCII names" do
    build = -> { described_class.new(company: company, year: 2026, submitter: submitter, draft: true, report: report).generate }
    person.update_columns(address_line1: nil)
    expect { build.call }.to raise_error(described_class::InvalidFile, /address/)
    person.update_columns(address_line1: "3 Main")
    row[:total_compensation] = -1
    expect { build.call }.to raise_error(described_class::InvalidFile, /amount/)
    row[:total_compensation] = 10_000_000_000
    expect { build.call }.to raise_error(described_class::InvalidFile, /amount/)
    row[:total_compensation] = 2345.67
    person.update_columns(first_name: "李")
    expect { build.call }.to raise_error(described_class::InvalidFile, /unsupported/)
  end

  it "uses EIN and allows an indeterminate business name control to remain blank" do
    person.update!(contractor_type: "business", contractor_ein: "66-2345678", business_name: "ABC Services")
    row[:tin_type] = "EIN"
    b = generator.generate.byteslice(1500, 750)
    expect(b[6, 14]).to eq("    1662345678")
    expect(b[287, 40].strip).to eq("ABC SERVICES")
  end

  it "rejects aggregator total mismatch" do
    report[:totals][:reportable_compensation] = 1
    expect { generator.generate }.to raise_error(described_class::InvalidFile, /Aggregator Box 1/)
  end

  it "detects length, sequence, counts, money and a one-byte shift" do
    original = generator.generate.scan(/.{748}\r\n/m)
    [ ->(r) { r[2].insert(54, '0') }, ->(r) { r[2][499, 8] = '00000009' },
      ->(r) { r[3][1, 8] = '00000002' }, ->(r) { r[4][49, 8] = '00000002' },
      ->(r) { r[3][15, 18] = '000000000000000001' },
      ->(r) { r[2] = ' ' + r[2][0...-1] } ].each do |mutate|
      records = original.map(&:dup)
      mutate.call(records)
      expect { generator.self_check!(records) }.to raise_error(described_class::InvalidFile)
    end
  end
end
