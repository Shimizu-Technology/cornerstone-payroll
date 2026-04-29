# frozen_string_literal: true

require "rails_helper"

RSpec.describe InstallmentLoanReportPdfGenerator do
  it "passes the requested as_of_date to the installment loan report builder" do
    company = build_stubbed(:company)
    as_of_date = Date.new(2026, 3, 1)
    builder = instance_double(InstallmentLoanReportBuilder, loans: [])

    expect(InstallmentLoanReportBuilder).to receive(:new)
      .with(company, as_of_date: as_of_date)
      .and_return(builder)

    described_class.new(company, as_of_date: as_of_date).generate
  end
end
