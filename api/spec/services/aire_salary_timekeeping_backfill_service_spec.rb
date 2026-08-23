# frozen_string_literal: true

require "rails_helper"

RSpec.describe AireSalaryTimekeepingBackfillService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: :manager) }
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company,
      effective_on: Date.new(2024, 1, 1),
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: actor,
      confirmed_at: Time.current,
      notes: "Employer confirmed Sunday workweek"
    )
  end
  let(:employee) do
    create(
      :employee,
      :salary,
      company: company,
      department: nil,
      first_name: "Krystel",
      last_name: "Example",
      hire_date: Date.new(2024, 1, 1),
      salary_type: "annual",
      pay_rate: 52_000
    )
  end
  let(:pay_period) do
    create(
      :pay_period,
      :committed,
      company: company,
      company_workweek: workweek,
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 1, 14),
      pay_date: Date.new(2024, 1, 19),
      run_purpose: "regular",
      includes_base_salary: true
    )
  end
  let!(:payroll_item) do
    create(
      :payroll_item,
      :salary,
      company: company,
      employee: employee,
      pay_period: pay_period,
      pay_rate: 52_000,
      gross_pay: 2_000,
      net_pay: 1_600,
      withholding_tax: 200,
      social_security_tax: 124,
      medicare_tax: 29
    )
  end

  def run_service(apply:)
    described_class.call!(
      company_id: company.id,
      employee_id: employee.id,
      expected_employee_name: employee.full_name,
      effective_on: "2024-01-01",
      actor: actor,
      apply: apply
    )
  end

  it "is a dry run by default and identifies committed history without changing it" do
    result = run_service(apply: false)

    expect(result).to include(apply: false, payroll_item_ids: [ payroll_item.id ], changes_money: false)
    expect(employee.employee_work_profiles).to be_empty
    expect(employee.daily_time_records).to be_empty
  end

  it "backfills hours and audit records without recalculating payroll dollars" do
    money_before = payroll_item.attributes.slice(*described_class::MONEY_COLUMNS)

    result = run_service(apply: true)

    expect(result[:daily_time_record_count]).to be_positive
    expect(payroll_item.reload.attributes.slice(*described_class::MONEY_COLUMNS)).to eq(money_before)
    expect(payroll_item).to have_attributes(scheduled_hours: 80.to_d, hours_worked: 80.to_d, timekeeping_source: "production_backfill")
    expect(employee.employee_work_profiles.last).to have_attributes(overtime_status: "needs_review", standard_weekly_hours: 40.to_d)
  end

  it "refuses to rely on a fuzzy name match" do
    expect do
      described_class.call!(
        company_id: company.id,
        employee_id: employee.id,
        expected_employee_name: "Krystal Example",
        effective_on: "2024-01-01",
        actor: actor,
        apply: false
      )
    end.to raise_error(described_class::Error, /exactly match/)
  end

  it "excludes a voided original and backfills its committed correction against the shared dates" do
    pay_period.update!(correction_status: "voided")
    correction_period = create(
      :pay_period,
      :committed,
      company: company,
      company_workweek: workweek,
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      pay_date: pay_period.pay_date,
      correction_status: "correction",
      source_pay_period: pay_period,
      run_purpose: "correction",
      run_purpose_source: "system_correction",
      includes_base_salary: true
    )
    correction_item = create(
      :payroll_item,
      :salary,
      company: company,
      employee: employee,
      pay_period: correction_period,
      pay_rate: 52_000,
      gross_pay: 2_000,
      net_pay: 1_600
    )

    result = run_service(apply: true)

    expect(result[:payroll_item_ids]).to contain_exactly(correction_item.id)
    expect(payroll_item.reload.scheduled_hours).to eq(0.to_d)
    expect(correction_item.reload.scheduled_hours).to eq(80.to_d)
    expect(employee.daily_time_records.current.group(:work_date).count.values).to all(eq(1))
  end
end
