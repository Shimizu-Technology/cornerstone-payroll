# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "compensation:reconcile_rollout" do
  include ActiveSupport::Testing::TimeHelpers

  it "records newer legacy caches as dated history, prints only IDs/counts, and is safe to rerun" do
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    load Rails.root.join("lib/tasks/compensation.rake")
    Rake::Task.define_task(:environment)
    task = Rake::Task["compensation:reconcile_rollout"]
    employee = create(:employee, pay_rate: 15, hire_date: PayrollBusinessClock.today - 60)
    wage_rate = employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true)
    employee.employee_compensation_changes.update_all(source: "backfill", created_at: 1.day.ago)
    wage_rate.employee_wage_rate_versions.update_all(source: "backfill", created_at: 1.day.ago)

    employee.update_columns(pay_rate: 18, updated_at: Time.current)
    wage_rate.update_columns(label: "Core shift", rate: 18, updated_at: Time.current)
    expect { task.invoke }.to output("employee_id=#{employee.id} wage_rate_ids=#{wage_rate.id}\nemployee_count=1 wage_rate_count=1\n").to_stdout
    expect(AuditLog.find_by!(action: "employee#compensation_changed", record_id: employee.id))
      .to have_attributes(actor_name: "Compensation rollout reconciliation", actor_role: "system_job", user_id: nil)
    today = PayrollBusinessClock.today
    expect(employee.reload.payroll_rate_on(today)).to eq(18)
    expect(employee.payroll_rate_on(today - 1)).to eq(15)
    expect(employee.wage_rates_on(today).sole).to have_attributes(label: "Core shift", rate: 18)

    task.reenable
    expect { task.invoke }.to output("employee_count=0 wage_rate_count=0\n").to_stdout
    expect(employee.employee_compensation_changes.count).to eq(2)
    expect(wage_rate.employee_wage_rate_versions.count).to eq(2)
  ensure
    Rake.application = previous_application
  end
  it "records legacy basis drift after a future locked period without changing its pay basis" do
    today = PayrollBusinessClock.today
    employee = create(:employee, pay_rate: 15)
    employee.employee_compensation_changes.update_all(source: "backfill")
    period = create(:pay_period, :approved, company: employee.company, start_date: today - 5,
      end_date: today + 8, pay_date: today + 12)
    create(:payroll_item, employee: employee, company: employee.company, pay_period: period, gross_pay: 1200)
    employee.update_columns(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)

    service = EmployeeCompensationChangeService
    expect(service.reconcile_rollout!(employee.id, as_of: today)).to include(employee_id: employee.id)
    employee.reload
    expect(employee.compensation_on(period.end_date)).to have_attributes(employment_type: "hourly", pay_rate: 15)
    expect(employee.compensation_on(period.end_date + 1)).to have_attributes(employment_type: "salary", pay_rate: 52_000)
    expect(employee.pay_rate).to eq(15)
    expect(period.payroll_items.sole.gross_pay).to eq(1200)
    expect(service.reconcile_rollout!(employee.id, as_of: today)).to be_nil
  end
end
