# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFilingResponsibility, type: :model do
  it "requires a quarter for quarterly filing types" do
    record = build(:payroll_filing_responsibility, quarter: nil, filing_type: "form_941")

    expect(record).not_to be_valid
    expect(record.errors[:quarter]).to include("must be 1, 2, 3, or 4 for quarterly filings")
  end

  it "forbids a quarter for annual filing types" do
    record = build(:payroll_filing_responsibility, filing_type: "w2_gu", quarter: 1)

    expect(record).not_to be_valid
    expect(record.errors[:quarter]).to include("must be blank for annual filings")
  end

  it "allows the client and no-filing parties only for the year-end W-2GU and 1099 decisions" do
    %w[client no_filing].each do |party|
      quarterly = build(:payroll_filing_responsibility, filing_type: "form_941", responsible_party: party)
      expect(quarterly).not_to be_valid
      expect(quarterly.errors[:responsible_party]).to include("can be the client or no filing only for W-2GU and 1099 decisions")

      %w[w2_gu form_1099].each do |filing_type|
        expect(build(:payroll_filing_responsibility, :annual, filing_type: filing_type, responsible_party: party)).to be_valid
      end
    end
  end

  it "keeps quarterly filing owners independent" do
    form_941 = create(:payroll_filing_responsibility, filing_type: "form_941")
    swica = build(
      :payroll_filing_responsibility,
      company: form_941.company,
      reviewed_by: form_941.reviewed_by,
      filing_type: "swica"
    )

    expect(swica).to be_valid
  end

  it "enforces one annual W-2GU decision per company and year" do
    existing = create(:payroll_filing_responsibility, :annual)
    duplicate = build(
      :payroll_filing_responsibility,
      :annual,
      company: existing.company,
      reviewed_by: existing.reviewed_by
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:company_id]).to be_present
  end

  it "retains reviewer attribution after the user record is deleted" do
    record = create(:payroll_filing_responsibility)
    reviewer_name = record.reviewed_by_name

    record.reviewed_by.delete

    expect(record.reload.reviewed_by).to be_nil
    expect(record.reviewed_by_name).to eq(reviewer_name)
    expect(record.decision_payload.dig(:reviewed_by, :name)).to eq(reviewer_name)
  end
end
