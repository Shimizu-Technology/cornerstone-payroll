# frozen_string_literal: true

require "rails_helper"

RSpec.describe W2GuPdfGenerator do
  let(:report_data) do
    {
      meta: {
        report_type: "w2_gu",
        company_id: 1,
        company_name: "Shimizu Industries",
        year: 2025,
        generated_at: "2025-02-01T10:00:00Z",
        employee_count: 1,
        caveats: [ "This report is a preparation summary." ]
      },
      employer: {
        name: "Shimizu Industries",
        ein: "12-3456789",
        address: "123 Marine Drive, Tamuning, GU 96913"
      },
      totals: {
        box1_wages_tips_other_comp: 3100.0,
        box2_federal_income_tax_withheld: 250.0,
        box3_social_security_wages: 3000.0,
        box4_social_security_tax_withheld: 186.0,
        box5_medicare_wages_tips: 3100.0,
        box6_medicare_tax_withheld: 43.5,
        box7_social_security_tips: 100.0,
        reported_tips_total: 100.0
      },
      compliance_issues: [],
      employees: [
        {
          employee_id: 1,
          employee_name: "Alice Terlaje",
          employee_ssn_last4: "6789",
          employee_address: "1 Main St, Hagåtña, GU 96910",
          box1_wages_tips_other_comp: 3100.0,
          box2_federal_income_tax_withheld: 250.0,
          box3_social_security_wages: 3000.0,
          box4_social_security_tax_withheld: 186.0,
          box5_medicare_wages_tips: 3100.0,
          box6_medicare_tax_withheld: 43.5,
          box7_social_security_tips: 100.0,
          reported_tips_total: 100.0,
          box7_limited_by_wage_base: false,
          has_missing_ssn: false,
          has_missing_address: false
        }
      ]
    }
  end

  subject(:generator) { described_class.new(report_data) }

  describe "#generate" do
    it "returns binary PDF data" do
      pdf = generator.generate
      expect(pdf).to be_a(String)
      expect(pdf.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "starts with the PDF magic bytes" do
      pdf = generator.generate
      expect(pdf.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ]) # %PDF
    end

    it "generates without raising" do
      expect { generator.generate }.not_to raise_error
    end

    context "with compliance issues" do
      before do
        report_data[:compliance_issues] = [ "Employer EIN is missing", "2 employee(s) missing SSN" ]
        report_data[:employees].first[:has_missing_ssn] = true
        report_data[:employees].first[:employee_ssn_last4] = nil
      end

      it "generates without raising even with compliance issues" do
        expect { generator.generate }.not_to raise_error
      end
    end

    context "with no employees" do
      before { report_data[:employees] = [] }

      it "generates without raising when employee list is empty" do
        expect { generator.generate }.not_to raise_error
      end
    end

    context "with capped box 7" do
      before do
        report_data[:employees].first[:box7_limited_by_wage_base] = true
        report_data[:employees].first[:box7_social_security_tips] = 126_100.0
        report_data[:employees].first[:reported_tips_total] = 200_000.0
      end

      it "generates without raising when box7 is capped" do
        expect { generator.generate }.not_to raise_error
      end
    end

    context "with nil totals and nil collections" do
      before do
        report_data[:totals] = nil
        report_data[:employees] = nil
        report_data[:compliance_issues] = nil
      end

      it "generates without raising" do
        expect { generator.generate }.not_to raise_error
      end
    end
  end

  describe "#filename" do
    it "includes company slug and year" do
      expect(generator.filename).to eq("w2gu_shimizu_industries_2025.pdf")
    end
  end
end
