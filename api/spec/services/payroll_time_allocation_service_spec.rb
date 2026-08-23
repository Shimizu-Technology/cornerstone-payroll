# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollTimeAllocationService do
  let!(:tax_table) { create(:tax_table) }
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
      notes: "Confirmed Sunday workweek for test"
    )
  end
  let(:employee) do
    create(
      :employee,
      :salary,
      company: company,
      department: nil,
      pay_rate: 52_000,
      salary_type: "annual",
      pay_frequency: "biweekly",
      hire_date: Date.new(2024, 1, 1)
    )
  end
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 1, 14),
      pay_date: Date.new(2024, 1, 19),
      company_workweek: workweek,
      run_purpose: "regular",
      includes_base_salary: true
    )
  end
  let(:payroll_item) do
    create(:payroll_item, :salary, company: company, employee: employee, pay_period: pay_period, pay_rate: 52_000)
  end

  it "materializes an 80-hour biweekly salary schedule without changing base salary" do
    create(:employee_work_profile, employee: employee)

    described_class.call!(payroll_item: payroll_item)
    payroll_item.calculate!

    expect(payroll_item.reload).to have_attributes(
      scheduled_hours: 80.to_d,
      hours_worked: 80.to_d,
      overtime_hours: 0.to_d,
      timekeeping_source: "schedule",
      gross_pay: 2_000.to_d
    )
    expect(payroll_item.payroll_time_allocations.count).to eq(14)
    expect(employee.daily_time_records.current.count).to eq(20) # full intersecting workweeks, excluding the pre-hire boundary day
  end

  it "does not apply a newly effective schedule to dates before the profile began" do
    create(:employee_work_profile, employee: employee, effective_on: Date.new(2024, 1, 8))

    described_class.call!(payroll_item: payroll_item)

    expect(payroll_item.reload).to have_attributes(scheduled_hours: 40.to_d, hours_worked: 40.to_d)
    expect(payroll_item.payroll_time_allocations.pluck(:work_date)).to all(be >= Date.new(2024, 1, 8))
  end

  it "blocks a work-profile change that splits an intersecting legal workweek" do
    create(
      :employee_work_profile,
      employee: employee,
      effective_on: Date.new(2024, 1, 1),
      ends_on: Date.new(2024, 1, 7)
    )
    create(:employee_work_profile, employee: employee, effective_on: Date.new(2024, 1, 8))

    expect { described_class.call!(payroll_item: payroll_item) }
      .to raise_error(described_class::Error, /More than one salary work profile/)
    expect(employee.daily_time_records).to be_empty
  end

  it "keeps off-cycle salary hours and base salary at zero" do
    create(:employee_work_profile, employee: employee)
    pay_period.update!(run_purpose: "bonus", includes_base_salary: false)

    described_class.call!(payroll_item: payroll_item)
    payroll_item.calculate!

    expect(payroll_item.reload).to have_attributes(scheduled_hours: 0.to_d, hours_worked: 0.to_d, gross_pay: 0.to_d)
    expect(employee.daily_time_records).to be_empty
  end

  it "calculates weekly overtime for a confirmed nonexempt salary profile" do
    schedule = {
      "sunday" => 0, "monday" => 9, "tuesday" => 9, "wednesday" => 9,
      "thursday" => 9, "friday" => 9, "saturday" => 0
    }
    create(
      :employee_work_profile,
      employee: employee,
      overtime_status: "nonexempt",
      exemption_category: nil,
      exemption_reason: nil,
      standard_weekly_hours: 45,
      salary_covers_weekly_hours: 45,
      salary_coverage_reason: "Employment agreement confirms a 45-hour salary basis",
      daily_schedule: schedule
    )

    described_class.call!(payroll_item: payroll_item)
    payroll_item.calculate!

    expect(payroll_item.reload.overtime_hours).to eq(10.to_d)
    expect(payroll_item.timekeeping_context_snapshot).to include(
      "salary_covered_overtime_hours" => 10.0,
      "salary_uncovered_overtime_hours" => 0.0
    )
    expect(payroll_item.salary_overtime_pay).to eq(111.11)
    expect(payroll_item.gross_pay).to eq(2_111.11.to_d)
  end

  it "uses the current per-period override for variable nonexempt salary overtime" do
    employee.update!(salary_type: "variable", pay_rate: 0)
    payroll_item.update!(pay_rate: 0, salary_override: 2_000)
    schedule = {
      "sunday" => 0, "monday" => 9, "tuesday" => 9, "wednesday" => 9,
      "thursday" => 9, "friday" => 9, "saturday" => 0
    }
    create(
      :employee_work_profile,
      employee: employee,
      overtime_status: "nonexempt",
      exemption_category: nil,
      exemption_reason: nil,
      standard_weekly_hours: 45,
      salary_covers_weekly_hours: 40,
      salary_coverage_reason: "Employment agreement confirms a 40-hour salary basis",
      daily_schedule: schedule
    )

    described_class.call!(payroll_item: payroll_item)
    payroll_item.calculate!

    expect(payroll_item.reload.overtime_hours).to eq(10.to_d)
    expect(payroll_item.timekeeping_context_snapshot).to include(
      "salary_covered_overtime_hours" => 0.0,
      "salary_uncovered_overtime_hours" => 10.0
    )
    expect(payroll_item.salary_overtime_pay).to eq(375.0)
    expect(payroll_item.gross_pay).to eq(2_375.0.to_d)
  end


  it "pays half-time within the salary basis and time-and-a-half beyond it" do
    schedule = {
      "sunday" => 0, "monday" => 10, "tuesday" => 10, "wednesday" => 10,
      "thursday" => 10, "friday" => 10, "saturday" => 0
    }
    create(
      :employee_work_profile,
      employee: employee,
      overtime_status: "nonexempt",
      exemption_category: nil,
      exemption_reason: nil,
      standard_weekly_hours: 50,
      salary_covers_weekly_hours: 45,
      salary_coverage_reason: "Employment agreement confirms a 45-hour salary basis",
      daily_schedule: schedule
    )

    described_class.call!(payroll_item: payroll_item)
    payroll_item.calculate!

    expect(payroll_item.reload.overtime_hours).to eq(20.to_d)
    expect(payroll_item.timekeeping_context_snapshot).to include(
      "salary_covered_overtime_hours" => 10.0,
      "salary_uncovered_overtime_hours" => 10.0
    )
    expect(payroll_item.salary_overtime_pay).to eq(444.44)
    expect(payroll_item.gross_pay).to eq(2_444.44.to_d)
  end

  it "keeps covered and uncovered overtime correct across semimonthly boundaries" do
    create(:tax_table, pay_frequency: "semimonthly")
    employee.update!(pay_frequency: "semimonthly")
    schedule = {
      "sunday" => 0, "monday" => 10, "tuesday" => 10, "wednesday" => 10,
      "thursday" => 10, "friday" => 10, "saturday" => 0
    }
    create(
      :employee_work_profile,
      employee: employee,
      overtime_status: "nonexempt",
      exemption_category: nil,
      exemption_reason: nil,
      standard_weekly_hours: 50,
      salary_covers_weekly_hours: 45,
      salary_coverage_reason: "Employment agreement confirms a 45-hour salary basis",
      daily_schedule: schedule
    )
    first_period = create(
      :pay_period,
      company: company,
      company_workweek: workweek,
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 1, 15),
      pay_date: Date.new(2024, 1, 15),
      run_purpose: "regular",
      includes_base_salary: true
    )
    second_period = create(
      :pay_period,
      company: company,
      company_workweek: workweek,
      start_date: Date.new(2024, 1, 16),
      end_date: Date.new(2024, 1, 31),
      pay_date: Date.new(2024, 1, 31),
      run_purpose: "regular",
      includes_base_salary: true
    )
    items = [ first_period, second_period ].map do |period|
      create(:payroll_item, :salary, company: company, employee: employee, pay_period: period, pay_rate: 52_000)
    end

    items.each do |item|
      described_class.call!(payroll_item: item)
      item.calculate!
    end

    items.each do |item|
      expect(item.reload.overtime_hours).to eq(20.to_d)
      expect(item.timekeeping_context_snapshot).to include(
        "salary_covered_overtime_hours" => 10.0,
        "salary_uncovered_overtime_hours" => 10.0
      )
      expect(item.salary_overtime_pay).to eq(444.44)
      expect(item.gross_pay).to eq(2_611.11.to_d)
    end
    expect(employee.daily_time_records.current.group(:work_date).count.values).to all(eq(1))
  end

  it "preserves manually imported salary hours when no schedule profile exists" do
    payroll_item.update!(hours_worked: 76, overtime_hours: 0, timekeeping_source: "import")

    described_class.call!(payroll_item: payroll_item)

    expect(payroll_item.reload.hours_worked).to eq(76.to_d)
    expect(payroll_item.payroll_time_allocations).to be_empty
  end

  it "is idempotent when the same schedule-backed payroll is recalculated" do
    create(:employee_work_profile, employee: employee)

    2.times { described_class.call!(payroll_item: payroll_item) }

    expect(payroll_item.reload).to have_attributes(scheduled_hours: 80.to_d, hours_worked: 80.to_d)
    expect(payroll_item.payroll_time_allocations.count).to eq(14)
    expect(employee.daily_time_records.current.group(:work_date).count.values).to all(eq(1))
  end

  it "links a full correction run to the existing work dates without duplicating daily records" do
    create(:employee_work_profile, employee: employee)
    described_class.call!(payroll_item: payroll_item)
    original_record_ids = employee.daily_time_records.current.ids.sort

    source_period = create(
      :pay_period,
      :voided,
      company: company,
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      pay_date: pay_period.pay_date
    )
    correction_period = create(
      :pay_period,
      :committed,
      company: company,
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      pay_date: pay_period.pay_date,
      company_workweek: workweek,
      correction_status: "correction",
      source_pay_period: source_period,
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
      pay_rate: 52_000
    )

    described_class.call!(payroll_item: correction_item)

    expect(correction_item.reload).to have_attributes(scheduled_hours: 80.to_d, hours_worked: 80.to_d)
    expect(correction_item.payroll_time_allocations.count).to eq(14)
    expect(employee.daily_time_records.current.ids.sort).to eq(original_record_ids)
  end

  it "blocks salary overtime until a needs-review classification is resolved" do
    schedule = {
      "sunday" => 0, "monday" => 9, "tuesday" => 9, "wednesday" => 9,
      "thursday" => 9, "friday" => 9, "saturday" => 0
    }
    create(
      :employee_work_profile,
      employee: employee,
      overtime_status: "needs_review",
      exemption_category: nil,
      exemption_reason: nil,
      standard_weekly_hours: 45,
      daily_schedule: schedule
    )

    expect { described_class.call!(payroll_item: payroll_item) }
      .to raise_error(ActiveRecord::RecordInvalid, /Overtime status must be confirmed/)
    expect(payroll_item.reload.payroll_time_allocations).to be_empty
  end
end
