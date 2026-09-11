# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Variable salary finalization safety" do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, employment_type: "salary", salary_type: "variable", pay_rate: 100_000) }
  let(:period) { create(:pay_period, :calculated, company: company) }
  let(:item) do
    create(:payroll_item, pay_period: period, employee: employee, employment_type: "salary",
      pay_rate: employee.pay_rate, salary_override: nil, gross_pay: 900.00, net_pay: 800)
  end
  let(:service) { PayPeriodLifecycleService.new(pay_period: period, actor: nil) }

  it "blocks approval of a legacy saved bonus-only regular paycheck without changing its amounts" do
    saved = item.attributes
    expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Pay this period/)
    expect(period.reload.status).to eq("calculated")
    expect(item.reload.attributes).to eq(saved)
  end

  it "blocks commit of an already approved legacy row without posting money or changing its amounts" do
    item
    period.update!(status: "approved")
    saved = item.reload.attributes
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Pay this period/)
    expect(period.reload.status).to eq("approved")
    expect(item.reload.attributes).to eq(saved)
    expect(period.payroll_liability_postings).to be_empty
    expect(EmployeeYtdTotal.where(employee: employee)).to be_empty
  end

  it "uses the saved variable classification even if the profile has since changed" do
    item.update!(calculation_context_snapshot: { "employee" => { "employment_type" => "salary", "salary_type" => "variable" } })
    employee.update!(salary_type: "per_period")
    expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Pay this period/)
  end

  it "does not impose period pay on a paycheck calculated before an employee became variable salary" do
    item.update!(calculation_context_snapshot: { "employee" => { "employment_type" => "salary", "salary_type" => "annual" } })
    expect { service.approve! }.not_to raise_error
    expect(period.reload.status).to eq("approved")
  end

  it "allows approval of an off-cycle bonus that intentionally excludes base salary" do
    period.update!(status: "draft")
    period.update!(run_purpose: "bonus", includes_base_salary: false)
    item
    period.update!(status: "calculated")
    expect { service.approve! }.not_to raise_error
  end

  it "leaves committed historical payroll untouched" do
    item
    period.update!(status: "committed", committed_at: Time.current)
    saved = item.reload.attributes
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /approved pay period/)
    expect(item.reload.attributes).to eq(saved)
    expect(period.reload.status).to eq("committed")
  end
end
