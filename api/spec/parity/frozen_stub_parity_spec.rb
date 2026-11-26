# frozen_string_literal: true

require_relative "parity_helper"

# Production holds frozen employee pay stubs fingerprinted in older formats.
# Moving the check stub and reports onto one YTD source must not re-post any
# of them as "Corrected" while the printed figures are still right.
RSpec.describe "Frozen posted pay stubs across the shared YTD source", type: :request do
  include Parity::ParityContext

  let(:keys) { %i[hourly_overtime_p2 salaried_401k_p2 additional_withholding_med_p2 prior_provider_ytd_p2 native_non_taxable_p2] }
  let(:fixture_scenarios) { %i[hourly_overtime salaried_401k additional_withholding_med prior_provider_ytd native_non_taxable] }

  def recheck!(key, now:)
    TenantScope.as_system(reason: "Parity spec rechecks a posted pay stub") do
      EmployeeDocuments::PostPayStub.new(fixture.items.fetch(key).reload, now: now).call
    end
  end

  # The digest a stub posted before the Additional Medicare split recorded:
  # combined Medicare and the old tax labels (PayStubGenerator's legacy path).
  def record_old_format_fingerprint!(key)
    document = fixture.ensure_stub_posted!(key)
    legacy = PayStubGenerator.new(fixture.items.fetch(key).reload, employee_copy: true).send(:employee_payroll_fingerprint, legacy: true)
    expect(legacy).not_to eq(document.payroll_facts_sha256)
    EmployeeDocument.where(id: document.id).update_all(payroll_facts_sha256: legacy)
    document
  end

  it "keeps every old-format stub posted once its figures are rechecked, including a bridge employee" do
    documents = keys.index_with { |key| record_old_format_fingerprint!(key) }
    PayrollYtdSnapshotRefresh.mark_stubs_due!(fixture.items.values_at(*keys).map(&:id))

    keys.each { |key| recheck!(key, now: Parity::FixtureBuilder::POSTING_NOW + 1.day) }

    documents.each do |key, document|
      expect(document.reload).to be_posted, "#{key} was re-posted"
      expect(document.revision).to eq(1)
      expect(document.payroll_facts_checked_at).to be_present
      expect(EmployeeDocument.where(payroll_item_id: document.payroll_item_id).count).to eq(1)
    end
  end

  it "keeps current-format stubs posted and still revises one whose printed figure really changed" do
    documents = keys.index_with { |key| fixture.ensure_stub_posted!(key) }
    PayrollYtdSnapshotRefresh.mark_stubs_due!(fixture.items.values_at(*keys).map(&:id))
    keys.each { |key| recheck!(key, now: Parity::FixtureBuilder::POSTING_NOW + 1.day) }
    expect(documents.values.map { |document| document.reload.status }).to all(eq("posted"))

    # An earlier paycheck's income tax was wrong: the later stub's YTD moves.
    fixture.items.fetch(:hourly_overtime_p1).update_columns(withholding_tax: fixture.items.fetch(:hourly_overtime_p1).withholding_tax + 1)
    PayrollYtdSnapshotRefresh.mark_stubs_due!([ fixture.items.fetch(:hourly_overtime_p2).id ])
    revised = recheck!(:hourly_overtime_p2, now: Parity::FixtureBuilder::POSTING_NOW + 2.days)

    expect(revised.revision).to eq(2)
    expect(documents.fetch(:hourly_overtime_p2).reload).to be_replaced
  end
end
