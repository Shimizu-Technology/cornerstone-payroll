# frozen_string_literal: true

require "rails_helper"

RSpec.describe SwicaAsciiExporter do
  describe "#generate" do
    let(:company) { create(:company) }
    let(:employee) do
      create(:employee,
        company: company,
        first_name: "Juan",
        last_name: "Dela Cruz",
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Marine Corps Drive",
        city: "Tamuning",
        state: "GU",
        zip: "96913")
    end

    let(:report) do
      {
        meta: {
          company_id: company.id,
          year: 2026,
          quarter: 2
        },
        swica: {
          employees: [
            {
              employee_id: employee.id,
              name: employee.full_name,
              swica_wages: 1_234.56,
              guam_withholding: 78.90
            }
          ]
        }
      }
    end

    it "writes Guam SWICA Code W city/state and ZIP fields at the booklet offsets" do
      record = described_class.new(report).generate.lines.first.chomp

      expect(record.length).to eq(275)
      expect(record[0]).to eq("W")
      expect(record[1, 9]).to eq("123456789")
      # Guam DRT SWICA booklet defines positions 78-112 as one combined
      # "City and State or U.S. Possession" field, not separate city/state fields.
      expect(record[77, 35]).to eq("TAMUNING GU".ljust(35))
      # Positions 113-117 are Foreign Postal Code and should remain blank for Guam/U.S. addresses.
      expect(record[112, 5]).to eq(" " * 5)
      expect(record[117, 9]).to eq("96913".ljust(9))
      expect(record[274]).to eq("S")
    end

    it "normalizes non-ASCII employee text before fixed-width output" do
      employee.update!(
        first_name: "José",
        last_name: "Muña",
        address_line1: "123 Chålan Pågo",
        city: "Hagåtña"
      )

      record = described_class.new(report).generate.lines.first.chomp

      expect(record.length).to eq(275)
      expect(record.bytesize).to eq(275)
      expect(record).to be_ascii_only
      expect(record[10, 27]).to include("JOSE MUNA")
      expect(record[37, 40]).to include("123 CHALAN PAGO")
      expect(record[77, 35]).to include("HAGATNA GU")
    end
  end
end
