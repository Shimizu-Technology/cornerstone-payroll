# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollSubmissions::FileSet do
  it "rejects CSVs and misleading file extensions in the workbook slot" do
    company = create(:company)
    [ portal_upload("tips.csv", "name,tips\nSynthetic,1\n", "text/csv"), synthetic_pdf("tips.xlsx") ].each do |file|
      expect do
        described_class.new(company_id: company.id, files: [ [ "changes_workbook", file ] ]).prepare!
      end.to raise_error(described_class::Invalid)
    end
  end
end
