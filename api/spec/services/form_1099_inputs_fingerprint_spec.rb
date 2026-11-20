# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form1099InputsFingerprint do
  let(:company) do
    create(:company, ein: "98-7654321", address_line1: "123 Marine Corps Dr", city: "Tamuning", state: "GU", zip: "96913")
  end
  let(:department) { create(:department, company: company) }
  let!(:contractor) do
    create(:employee, :contractor, company: company, department: department, first_name: "Ana", last_name: "Cruz",
      ssn_encrypted: "345-67-7890", address_line1: "7 Route 8", city: "Maite", state: "GU", zip: "96910", w9_on_file: true)
  end

  before do
    create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000)
    period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 4, 21), end_date: Date.new(2026, 5, 5), pay_date: Date.new(2026, 5, 8))
    create(:payroll_item, company: company, employee: contractor, pay_period: period, employment_type: "contractor",
      gross_pay: 2_500, net_pay: 2_500, withholding_tax: 0, social_security_tax: 0, medicare_tax: 0,
      employer_social_security_tax: 0, employer_medicare_tax: 0)
  end

  def fingerprint
    described_class.new(company: company, year: 2026).call
  end

  it "changes when the payee's full TIN changes, even with the same last four digits" do
    before = fingerprint
    contractor.update!(ssn_encrypted: "456-12-7890")
    expect(fingerprint).not_to eq(before)
  end

  # The checklist returns this fingerprint with each payee's TIN last four,
  # so the TIN must go in under a server-held key: with another key, the
  # same inputs give another digest.
  it "keys the TIN component, so the digest can't be recomputed without the server's key" do
    with_server_key = fingerprint
    allow(TaxIdDigest).to receive(:key).and_return("another key, not the server's".ljust(32, "x"))
    expect(fingerprint).not_to eq(with_server_key)
    expect(fingerprint).to eq(fingerprint)
  end
end
