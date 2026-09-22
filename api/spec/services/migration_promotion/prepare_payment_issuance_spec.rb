# frozen_string_literal: true

require "rails_helper"

RSpec.describe MigrationPromotion::PreparePaymentIssuance do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, next_check_number: 5001) }
  let(:admin) { create(:user, company: company, organization: organization, role: "admin") }
  let(:source_batch) do
    create(:historical_import_batch, company: company, status: "locked", importer_version: "legacy-test-importer")
  end
  let(:rehearsal) do
    create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "migration_rehearsal",
      migration_source_company: company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready"
    )
  end
  let(:source_period) do
    create(
      :pay_period,
      company: rehearsal,
      start_date: Date.new(2026, 9, 7),
      end_date: Date.new(2026, 9, 20),
      pay_date: Date.new(2026, 9, 24),
      status: "approved"
    )
  end
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: source_period.start_date,
      end_date: source_period.end_date,
      pay_date: source_period.pay_date,
      status: "committed",
      run_purpose_source: "production_migration",
      promotion_source_pay_period: source_period,
      promotion_payment_disposition: "record_only",
      committed_at: Time.current,
      committed_by_id: admin.id,
      tax_sync_status: nil
    )
  end
  let!(:first_item) do
    create(
      :payroll_item,
      company: company,
      pay_period: pay_period,
      employee: create(:employee, company: company, first_name: "Ana", last_name: "One"),
      payment_delivery_method: "paper_check",
      gross_pay: 1_000,
      net_pay: 800
    )
  end
  let!(:second_item) do
    create(
      :payroll_item,
      company: company,
      pay_period: pay_period,
      employee: create(:employee, company: company, first_name: "Ben", last_name: "Two"),
      payment_delivery_method: "paper_check",
      gross_pay: 900,
      net_pay: 700
    )
  end
  let!(:zero_item) do
    create(
      :payroll_item,
      company: company,
      pay_period: pay_period,
      employee: create(:employee, company: company, first_name: "Zero", last_name: "Net"),
      payment_delivery_method: "paper_check",
      gross_pay: 0,
      net_pay: 0
    )
  end

  subject(:service) do
    described_class.new(
      pay_period: pay_period,
      actor: admin,
      acknowledgement: described_class::ACKNOWLEDGEMENT,
      starting_check_number: "5001",
      check_date: "2026-09-24",
      ip_address: "127.0.0.1"
    )
  end

  it "assigns auditable checks without replaying committed financial effects" do
    employee_ytd = EmployeeYtdTotal.create!(employee: first_item.employee, year: 2026, gross_pay: 1_000, net_pay: 800)
    company_ytd = CompanyYtdTotal.create!(company: company, year: 2026, gross_pay: 1_900, net_pay: 1_500)
    posting = PayrollLiabilityPosting.create!(
      company: company,
      pay_period: pay_period,
      posting_type: "historical_backfill",
      liability_date: pay_period.pay_date,
      posted_at: Time.current,
      posted_by: admin,
      idempotency_key: "prepare-payment-test-#{pay_period.id}"
    )

    result = service.call

    expect(result).to include(eligible: true, paper_check_count: 2, already_prepared: false)
    expect([ first_item.reload.check_number, second_item.reload.check_number ]).to eq(%w[5001 5002])
    expect([ first_item.check_date, second_item.check_date ]).to all(eq(Date.new(2026, 9, 24)))
    expect(zero_item.reload).to have_attributes(check_number: nil, check_date: nil)
    expect(company.reload.next_check_number).to eq(5003)
    expect(CheckEvent.where(payroll_item_id: [ first_item.id, second_item.id ], event_type: "assigned").count).to eq(2)
    expect(pay_period.reload).to have_attributes(
      promotion_payment_disposition: "process_in_cornerstone",
      promoted_payment_prepared_by: admin
    )
    expect(pay_period.promoted_payment_prepared_at).to be_present
    expect(employee_ytd.reload).to have_attributes(gross_pay: 1_000.to_d, net_pay: 800.to_d)
    expect(company_ytd.reload).to have_attributes(gross_pay: 1_900.to_d, net_pay: 1_500.to_d)
    expect(posting.reload).to be_present
    expect(pay_period.payroll_liability_postings.count).to eq(1)
    expect(AuditLog.where(company: company, action: "migration_promotion#payment_prepared", record_id: pay_period.id)).to exist
  end

  it "is idempotent after a successful preparation" do
    first = service.call
    second = service.call

    expect(first[:already_prepared]).to be(false)
    expect(second[:already_prepared]).to be(true)
    expect(company.reload.next_check_number).to eq(5003)
    expect(CheckEvent.where(payroll_item_id: [ first_item.id, second_item.id ], event_type: "assigned").count).to eq(2)
  end

  it "previews the exact check range without changing data" do
    preview = described_class.new(pay_period: pay_period, actor: admin).preview

    expect(preview).to include(
      eligible: true,
      paper_check_count: 2,
      paper_check_total: 1_500.to_d,
      suggested_first_check_number: "5001",
      suggested_last_check_number: "5002"
    )
    expect(first_item.reload.check_number).to be_nil
    expect(company.reload.next_check_number).to eq(5001)
  end

  it "blocks partial paper-check preparation when a positive direct deposit exists" do
    create(
      :payroll_item,
      company: company,
      pay_period: pay_period,
      employee: create(:employee, company: company),
      payment_delivery_method: "direct_deposit",
      gross_pay: 600,
      net_pay: 500
    )

    preview = described_class.new(pay_period: pay_period, actor: admin).preview
    expect(preview[:eligible]).to be(false)
    expect(preview[:blockers]).to include("Resolve positive-net direct deposits before preparing paper checks")
    expect { service.call }.to raise_error(ArgumentError, /direct deposits/)
  end

  it "rejects accountants even when they can access the client" do
    accountant = create(:user, company: company, organization: organization, role: "accountant")

    expect {
      described_class.new(pay_period: pay_period, actor: accountant).preview
    }.to raise_error(ArgumentError, /organization administrator/)
  end
end
