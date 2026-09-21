# frozen_string_literal: true

require "rails_helper"

RSpec.describe MigrationPromotion::Apply do
  let(:organization) { create(:organization) }
  let(:target_company) { create(:company, organization: organization, name: "MoSa's Hotbox — Clean Migration") }
  let(:actor) { create(:user, company: target_company, organization: organization, role: "admin") }
  let(:source_batch) do
    create(
      :historical_import_batch,
      company: target_company,
      status: "locked",
      importer_version: "legacy-test-importer"
    )
  end
  let(:rehearsal) do
    create(
      :company,
      organization: organization,
      name: "MoSa's Migration Test",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "migration_rehearsal",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready"
    )
  end
  let!(:target_employee) do
    create(
      :employee,
      company: target_company,
      department: create(:department, company: target_company),
      first_name: "Ana",
      last_name: "Existing",
      pay_rate: 15,
      payment_delivery_method: "direct_deposit"
    )
  end
  let!(:source_employee) do
    create(
      :employee,
      company: rehearsal,
      department: create(:department, company: rehearsal),
      test_workspace_source_employee: target_employee,
      first_name: "Ana",
      last_name: "Updated",
      pay_rate: 22,
      payment_delivery_method: "direct_deposit"
    )
  end
  let!(:new_source_employee) do
    create(
      :employee,
      company: rehearsal,
      department: source_employee.department,
      first_name: "New",
      last_name: "Employee",
      pay_rate: 19
    )
  end
  let!(:historical_target_employee) do
    create(:employee, company: target_company, status: "inactive", first_name: "Archived", last_name: "Identity")
  end
  let!(:historical_worker) do
    create(
      :historical_worker,
      historical_import_batch: source_batch,
      company: target_company,
      employee: historical_target_employee,
      external_key: "archived-identity",
      mapping_status: "exact_match"
    )
  end
  let!(:historical_employee_ytd) do
    EmployeeYtdTotal.create!(employee: historical_target_employee, year: 2025, gross_pay: 9_000, net_pay: 7_000)
  end
  let!(:first_source_period) do
    create_source_period(
      start_date: Date.new(2026, 8, 24),
      end_date: Date.new(2026, 9, 6),
      pay_date: Date.new(2026, 9, 10),
      status: "calculated",
      items: [ [ source_employee, 1_200, 960 ] ]
    )
  end
  let!(:second_source_period) do
    create_source_period(
      start_date: Date.new(2026, 9, 7),
      end_date: Date.new(2026, 9, 20),
      pay_date: Date.new(2026, 9, 24),
      status: "approved",
      items: [ [ source_employee, 1_300, 1_020 ], [ new_source_employee, 800, 690 ] ]
    )
  end
  let!(:source_loan_deduction_type) do
    DeductionType.create!(
      company: rehearsal,
      name: "Employee advance",
      category: "post_tax",
      sub_category: "loan",
      active: true
    )
  end
  let!(:source_loan) do
    EmployeeLoan.create!(
      company: rehearsal,
      employee: source_employee,
      deduction_type: source_loan_deduction_type,
      name: "Employee advance",
      original_amount: 500,
      current_balance: 500,
      payment_amount: 100,
      start_date: Date.new(2026, 8, 1),
      first_deduction_date: first_source_period.pay_date,
      status: "active"
    )
  end
  let!(:source_employee_deduction) do
    EmployeeDeduction.create!(
      employee: source_employee,
      deduction_type: source_loan_deduction_type,
      amount: 100,
      active: true
    )
  end
  let!(:source_loan_payroll_deductions) do
    [ first_source_period, second_source_period ].map do |period|
      PayrollItemDeduction.create!(
        payroll_item: period.payroll_items.find_by!(employee: source_employee),
        deduction_type: source_loan_deduction_type,
        employee_loan: source_loan,
        amount: 100,
        category: "post_tax",
        label: source_loan_deduction_type.name,
        loan_schedule_snapshot: {}
      )
    end
  end
  let!(:replaceable_draft) do
    create(
      :pay_period,
      company: target_company,
      start_date: first_source_period.start_date,
      end_date: first_source_period.end_date,
      pay_date: first_source_period.pay_date
    )
  end
  let!(:existing_employee_ytd) do
    EmployeeYtdTotal.create!(employee: target_employee, year: 2026, gross_pay: 100, net_pay: 80)
  end
  let!(:existing_company_ytd) do
    CompanyYtdTotal.create!(company: target_company, year: 2026, gross_pay: 200, net_pay: 160)
  end
  let!(:backup) do
    create(
      :company,
      organization: organization,
      name: "MoSa's Hotbox — Backup",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "backup_snapshot",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready",
      test_workspace_sealed_at: Time.current,
      test_workspace_manifest: {
        "promotion_source_rehearsal_id" => rehearsal.id,
        "source_fingerprint" => MigrationPromotion::TargetFingerprint.call(target_company)
      }
    )
  end

  def create_source_period(start_date:, end_date:, pay_date:, status:, items:)
    period = create(
      :pay_period,
      company: rehearsal,
      start_date: start_date,
      end_date: end_date,
      pay_date: pay_date,
      status: status
    )
    items.each do |employee, gross_pay, net_pay|
      create(
        :payroll_item,
        pay_period: period,
        employee: employee,
        gross_pay: gross_pay,
        net_pay: net_pay,
        withholding_tax: gross_pay - net_pay,
        hours_worked: 80
      )
    end
    period
  end

  subject(:apply) do
    described_class.new(
      rehearsal: rehearsal,
      actor: actor,
      acknowledgement: described_class::ACKNOWLEDGEMENT
    ).call
  end

  it "atomically replaces the empty draft, synchronizes setup, and records both payrolls without payment side effects" do
    expect { apply }.to change { target_company.pay_periods.committed.count }.from(0).to(2)

    promoted = target_company.pay_periods.committed.period_chronological.to_a
    expect(replaceable_draft.class.exists?(replaceable_draft.id)).to be(false)
    expect(promoted.map(&:promotion_source_pay_period_id)).to eq([ first_source_period.id, second_source_period.id ])
    expect(promoted).to all(have_attributes(run_purpose_source: "production_migration", parallel_run: false))
    expect(promoted).to all(have_attributes(tax_sync_status: nil, tax_sync_idempotency_key: nil))
    expect(promoted.first.payroll_items.sole.payment_delivery_method).to eq("direct_deposit")
    expect(promoted.flat_map(&:payroll_items)).to all(have_attributes(check_number: nil, check_printed_at: nil))
    expect(promoted.sum { |period| period.payroll_items.sum(:gross_pay) }).to eq(3_300.to_d)
    expect(promoted.sum { |period| period.payroll_items.sum(:net_pay) }).to eq(2_670.to_d)

    target_employee.reload
    expect(target_employee).to have_attributes(first_name: "Ana", last_name: "Updated", pay_rate: 22.to_d)
    expect(target_company.employees.find_by!(first_name: "New", last_name: "Employee").pay_rate).to eq(19.to_d)
    expect(EmployeeYtdTotal.find_by!(employee: target_employee, year: 2026)).to have_attributes(
      gross_pay: 2_600.to_d,
      net_pay: 2_060.to_d
    )
    expect(CompanyYtdTotal.find_by!(company: target_company, year: 2026)).to have_attributes(
      gross_pay: 3_500.to_d,
      net_pay: 2_830.to_d
    )
    expect(historical_employee_ytd.reload).to have_attributes(gross_pay: 9_000.to_d, net_pay: 7_000.to_d)
    expect(historical_target_employee.reload).to have_attributes(status: "inactive", first_name: "Archived")
    expect(promoted.map { |period| period.payroll_liability_postings.count }).to eq([ 1, 1 ])
    promoted_loan = target_company.employee_loans.find_by!(name: source_loan.name)
    expect(promoted_loan).to have_attributes(current_balance: 300.to_d, status: "active")
    expect(promoted_loan.loan_transactions.payments.count).to eq(2)

    expect(rehearsal.reload.test_workspace_sealed_at).to be_present
    expect(rehearsal.test_workspace_manifest).to include(
      "promotion_status" => "completed",
      "promotion_backup_company_id" => backup.id,
      "promoted_pay_period_ids" => promoted.map(&:id)
    )
    expect(AuditLog.where(action: "migration_promotion#completed", company: target_company)).to exist
  end

  it "rolls back target changes and leaves the verified backup intact when setup synchronization fails" do
    allow(MigrationPromotion::SetupSynchronizer).to receive(:new).and_raise("copy failed")

    expect { apply }.to raise_error(RuntimeError, "copy failed")

    expect(target_company.pay_periods.draft).to contain_exactly(replaceable_draft)
    expect(target_company.pay_periods.committed).to be_empty
    expect(target_employee.reload.last_name).to eq("Existing")
    expect(rehearsal.reload.test_workspace_sealed_at).to be_nil
    expect(backup.reload).to have_attributes(migration_rehearsal_status: "ready")
  end

  it "rejects accountants even when they can access both clients" do
    accountant = create(:user, company: target_company, organization: organization, role: "accountant")
    create(:company_assignment, user: accountant, company: rehearsal, workspace_access_level: "reviewer")

    expect {
      described_class.new(
        rehearsal: rehearsal,
        actor: accountant,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    }.to raise_error(ArgumentError, /organization administrator/)
  end
end
