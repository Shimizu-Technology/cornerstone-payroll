# frozen_string_literal: true

require "rails_helper"

RSpec.describe W2FilingInputsFingerprint do
  let(:company) { create(:company, ein: "12-3456789") }
  let(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department, ssn_encrypted: "123-45-6789") }

  before do
    period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 14), pay_date: Date.new(2026, 1, 18))
    create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 100, reported_tips: 0)
  end

  def fingerprint
    described_class.new(company: company, year: 2026).call
  end

  it "changes when the full SSN changes, even with the same last four digits" do
    before = fingerprint
    employee.update!(ssn_encrypted: "987-65-6789")
    expect(fingerprint).not_to eq(before)
  end

  # The fingerprint reaches the browser next to the SSN's last four digits,
  # so the SSN must go in under a server-held key: with another key, the
  # same inputs give another digest.
  it "keys the SSN component, so the digest can't be recomputed without the server's key" do
    with_server_key = fingerprint
    allow(TaxIdDigest).to receive(:key).and_return("another key, not the server's".ljust(32, "x"))
    expect(fingerprint).not_to eq(with_server_key)
    expect(fingerprint).to eq(fingerprint)
  end
end
