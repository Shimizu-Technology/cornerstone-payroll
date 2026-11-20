# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFilingRecord do
  let(:company) { create(:company) }
  def filing(agency:, **extra)
    described_class.new(company: company, filing_type: "w2_gu_w3_ss", tax_year: 2026, agency: agency,
      status: "submitted", submitted_at: Time.current, confirmation_number: "WFID", source_fingerprint: "a" * 64, **extra)
  end

  it "permits one W-2 submission per agency and preserves unassigned history" do
    %w[ssa drt legacy].each { |agency| filing(agency: agency).save! }
    expect(filing(agency: "ssa")).not_to be_valid
    expect(filing(agency: "drt", tax_year: 2025)).to be_valid
  end

  it "limits 1099s to DRT and leaves quarterly identity unchanged" do
    expect(filing(agency: "ssa", filing_type: "form_1099_nec")).not_to be_valid
    expect(filing(agency: "drt", filing_type: "form_1099_nec")).to be_valid
    expect(filing(agency: "ssa", filing_type: "w1", quarter: 1)).not_to be_valid
    expect(filing(agency: "", filing_type: "w1", quarter: 1)).to be_valid
  end
end
