# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrainingReplay::Cloner do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization, client_limit: 1) }
  let(:source_company) { create(:company, organization: organization, name: "Spike Coffee Roasters") }
  let(:actor) { create(:user, company: source_company, organization: organization, role: "admin") }
  let(:trainee) { create(:user, company: source_company, organization: organization, role: "accountant") }
  let!(:employee) { create(:employee, company: source_company, department: nil, first_name: "Ada", last_name: "Trainer") }

  let!(:prior_tax_year_source) do
    create_period(Date.new(2025, 12, 6), Date.new(2025, 12, 19), Date.new(2025, 12, 26), gross: 900, check_number: "500")
  end
  let!(:baseline_source) do
    create_period(Date.new(2026, 8, 8), Date.new(2026, 8, 21), Date.new(2026, 8, 28), gross: 1_000, check_number: "501")
  end
  let!(:first_practice_source) do
    create_period(Date.new(2026, 8, 22), Date.new(2026, 9, 4), Date.new(2026, 9, 11), gross: 1_200, check_number: "502")
  end
  let!(:second_practice_source) do
    create_period(Date.new(2026, 9, 5), Date.new(2026, 9, 18), Date.new(2026, 9, 25), gross: 1_350, check_number: "503")
  end

  before { ActiveJob::Base.queue_adapter = :test }
  after { clear_enqueued_jobs }

  it "uses a calculated latest period without committing it" do
    trainee
    second_practice_source.update_columns(status: "calculated", committed_at: nil)

    preview = TrainingReplay::Preview.new(source_company: source_company).call

    expect(preview).to include(ready: true, blockers: [])
    expect(preview.fetch(:practice_periods).map { |row| row.fetch(:status) }).to eq(%w[committed calculated])
  end

  it "creates explicit staff access and queues an isolated training copy" do
    expect {
      @target = TrainingReplay::Create.new(
        source_company: source_company,
        actor: actor,
        acknowledgement: TrainingReplay::Create::ACKNOWLEDGEMENT,
        assignments: [ { user_id: trainee.id, workspace_access_level: "operator" } ]
      ).call
    }.to have_enqueued_job(TrainingReplay::CloneJob)

    expect(@target).to have_attributes(
      test_workspace_purpose: "training_replay",
      migration_rehearsal_status: "pending",
      migration_source_company_id: source_company.id,
      active_printer_profile_id: nil
    )
    expect(@target.test_workspace_manifest.fetch("practice_source_pay_period_ids")).to eq([
      first_practice_source.id,
      second_practice_source.id
    ])
    expect(@target.company_assignments.sole).to have_attributes(
      user_id: trainee.id,
      workspace_access_level: "operator",
      granted_by_id: actor.id
    )
  end

  it "copies older payroll as locked baseline and seeds two input-only practice runs" do
    personal_field = create(
      :payroll_field_definition,
      company: source_company,
      owner_employee: employee,
      name: "Ada phone allowance",
      default_amount: 25
    )
    EmployeePayrollField.create!(
      employee: employee,
      payroll_field_definition: personal_field,
      amount: 25,
      start_date: Date.new(2026, 1, 1)
    )
    target = build_target

    described_class.new(company: target, actor: actor).call

    target.reload
    copied_employee = target.employees.sole
    baseline = target.pay_periods.find_by!(test_workspace_role: "baseline")
    practices = target.pay_periods.where(test_workspace_role: "practice").period_chronological.to_a

    expect(target.migration_rehearsal_status).to eq("ready")
    expect(target.pay_periods.where(test_workspace_role: "baseline").count).to eq(1)
    expect(target.pay_periods.where(test_workspace_source_pay_period: prior_tax_year_source)).to be_empty
    expect(copied_employee.test_workspace_source_employee).to eq(employee)
    copied_field = target.payroll_field_definitions.find_by!(name: "Ada phone allowance")
    expect(copied_field.owner_employee).to eq(copied_employee)
    expect(copied_employee.employee_payroll_fields.sole.payroll_field_definition).to eq(copied_field)
    expect(baseline).to have_attributes(
      status: "approved",
      test_workspace_source_pay_period_id: baseline_source.id,
      parallel_run: true
    )
    expect(baseline.payroll_items.sole).to have_attributes(gross_pay: 1_000.to_d, check_number: nil)
    expect(practices.map(&:test_workspace_source_pay_period_id)).to eq([
      first_practice_source.id,
      second_practice_source.id
    ])
    expect(practices.map(&:status)).to eq(%w[draft draft])
    expect(practices.map { |period| period.payroll_items.sole.hours_worked }).to eq([ 72.to_d, 72.to_d ])
    expect(practices.map { |period| period.payroll_items.sole.gross_pay }).to eq([ 0.to_d, 0.to_d ])
    expect(target.payroll_items.where.not(check_number: nil)).to be_empty
    expect(target.training_replay_benchmarks.order(:source_pay_period_id).pluck(:source_status)).to eq(%w[committed committed])

    expect(baseline.update(notes: "changed")).to be(false)
    expect(baseline.errors.full_messages.join).to include("locked benchmark evidence")
    expect(baseline.payroll_items.sole.update(gross_pay: 5)).to be(false)
  end

  it "previews only same-tax-year baseline payroll" do
    preview = TrainingReplay::Preview.new(source_company: source_company).call

    expect(preview.dig(:copy_summary, :baseline_pay_periods)).to eq(1)
  end

  it "compares a practice run to its linked live benchmark using employee lineage" do
    target = build_target
    described_class.new(company: target, actor: actor).call
    practice = target.pay_periods.find_by!(test_workspace_source_pay_period: first_practice_source)
    practice.payroll_items.sole.update!(gross_pay: 1_100, net_pay: 900)
    added_employee = create(:employee, company: target, department: nil, first_name: "New", last_name: "Trainee")
    create(:payroll_item, company: target, pay_period: practice, employee: added_employee, gross_pay: 100, net_pay: 80)

    result = PayPeriodComparisonBuilder.new(practice).call

    expect(result).to include(comparison_kind: "training_benchmark")
    expect(result.dig(:previous_pay_period, :id)).to eq(first_practice_source.id)
    expect(result.dig(:summary, :gross_pay)).to include(current: 1_200.0, previous: 1_200.0, delta: 0.0)
    copied_employee = target.employees.find_by!(test_workspace_source_employee: employee)
    mapped_change = result.fetch(:employee_changes).find { |change| change.fetch(:employee_id) == copied_employee.id }
    expect(mapped_change).to be_present
    added_flag = result.fetch(:employee_changes)
      .find { |change| change.fetch(:employee_id) == added_employee.id }
      .fetch(:flags)
      .find { |flag| flag.fetch(:key) == "new_employee" }
    expect(added_flag.fetch(:message)).to include("training benchmark")
  end

  it "freezes a calculated source result so later live changes cannot alter training comparison" do
    second_practice_source.update_columns(status: "calculated", committed_at: nil)
    target = build_target

    described_class.new(company: target, actor: actor).call

    practice = target.pay_periods.find_by!(test_workspace_source_pay_period: second_practice_source)
    benchmark = practice.training_replay_benchmark
    original_expected = PayPeriodComparisonBuilder.new(practice).call.dig(:summary, :gross_pay, :previous)
    second_practice_source.payroll_items.sole.update!(gross_pay: 99_999, net_pay: 88_888)
    second_practice_source.update_columns(status: "draft")

    comparison = PayPeriodComparisonBuilder.new(practice).call
    expect(comparison.dig(:summary, :gross_pay, :previous)).to eq(original_expected)
    expect(comparison.fetch(:benchmark)).to include(
      mode: "immutable_snapshot",
      immutable: true,
      source_status: "calculated"
    )
    expect(benchmark.update(source_status: "committed")).to be(false)
    expect(benchmark.errors.full_messages).to include("Training replay benchmarks are immutable")
  end

  it "carries a calculated practice loan payment into the second practice run without committing" do
    deduction_type = DeductionType.create!(
      company: source_company,
      name: "Employee loan",
      category: "post_tax",
      sub_category: "loan"
    )
    EmployeeLoan.create!(
      company: source_company,
      employee: employee,
      deduction_type: deduction_type,
      name: "Training loan",
      original_amount: 150,
      opening_balance: 150,
      current_balance: 150,
      balance_as_of: Date.new(2026, 8, 1),
      balance_source: "employee_confirmation",
      payment_amount: 100,
      first_deduction_date: Date.new(2026, 8, 1)
    )
    target = build_target
    described_class.new(company: target, actor: actor).call
    first_practice = target.pay_periods.find_by!(test_workspace_source_pay_period: first_practice_source)
    second_practice = target.pay_periods.find_by!(test_workspace_source_pay_period: second_practice_source)
    copied_loan = target.employee_loans.sole
    PayrollItemDeduction.create!(
      payroll_item: first_practice.payroll_items.sole,
      deduction_type: target.deduction_types.sole,
      employee_loan: copied_loan,
      amount: 100,
      category: "post_tax",
      label: "Employee loan"
    )
    first_practice.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: actor.id)

    expect(copied_loan.scheduled_payment_for(pay_date: second_practice.pay_date, requested_amount: 100)).to eq(50.to_d)
    expect(copied_loan.reload.current_balance).to eq(150.to_d)
  end

  it "restores a recurring deduction that was stopped after the training cutoff" do
    deduction_type = DeductionType.create!(
      company: source_company,
      name: "Recurring allotment",
      category: "post_tax",
      sub_category: "loan"
    )
    EmployeeLoan.create!(
      company: source_company,
      employee: employee,
      deduction_type: deduction_type,
      name: "Training allotment",
      tracking_mode: "recurring_no_balance",
      status: "stopped",
      payment_amount: 25,
      first_deduction_date: Date.new(2026, 8, 1),
      stopped_at: Time.zone.parse("2026-09-20 12:00"),
      stopped_by: actor
    )
    target = build_target

    described_class.new(company: target, actor: actor).call

    expect(target.employee_loans.sole).to have_attributes(
      status: "active",
      stopped_at: nil,
      stopped_by_id: nil
    )
  end

  private

  def create_period(start_date, end_date, pay_date, gross:, check_number:)
    period = create(
      :pay_period,
      :committed,
      company: source_company,
      start_date: start_date,
      end_date: end_date,
      pay_date: pay_date,
      calculated_at: pay_date - 2.days,
      approved_at: pay_date - 1.day
    )
    create(
      :payroll_item,
      pay_period: period,
      company: source_company,
      employee: employee,
      hours_worked: 72,
      gross_pay: gross,
      net_pay: gross - 200,
      withholding_tax: 100,
      social_security_tax: 62,
      medicare_tax: 14.50,
      total_deductions: 200,
      check_number: check_number
    )
    period
  end

  def build_target
    Company.create!(
      organization: organization,
      name: "Spike Coffee Roasters Training Replay",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "training_replay",
      migration_source_company: source_company,
      migration_rehearsal_status: "pending",
      migration_rehearsal_created_by: actor,
      migration_rehearsal_created_at: Time.current,
      test_workspace_manifest: {
        "version" => 1,
        "purpose" => "training_replay",
        "practice_source_pay_period_ids" => [ first_practice_source.id, second_practice_source.id ]
      },
      payroll_intake_source_types: []
    )
  end
end
