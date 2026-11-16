# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollHistoryQuery do
  let(:company) { create(:company, client_payroll_approval_required: true) }
  let(:period) { create(:pay_period, :approved, company: company) }

  def review(**attrs)
    period.payroll_review_packages.create!(company: company, revision: 1, schema_version: 1,
      calculation_checksum: "a" * 64, calculation_snapshot: {}, source_manifest: {}, generated_at: Time.current, **attrs)
  end

  it "removes a published run from client history when review is disabled" do
    package = review(published_at: Time.current)
    expect(described_class.new(company_id: company.id, params: {}, audience: :client).call.data.map { |row| row[:id] }).to include(period.id)
    company.update!(client_payroll_approval_required: false)
    expect(described_class.new(company_id: company.id, params: {}, audience: :client).call.data).to be_empty
    expect(package.reload.published_at).to be_present
  end

  [ true, false ].each do |required|
    it "hides Commit during a pending change request with required approval #{required}" do
      company.update!(client_payroll_approval_required: required)
      review(published_at: Time.current,
        changes_requested_at: Time.current, changes_requested_by: create(:user, company: company, role: "client"), change_request_note: "Add hours")
      row = described_class.new(company_id: company.id, params: {}).call.data.first
      expect(row[:capabilities][:commit]).to be(false)
    end
  end
end
