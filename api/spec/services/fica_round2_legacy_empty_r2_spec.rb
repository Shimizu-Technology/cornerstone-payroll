# frozen_string_literal: true

require "rails_helper"
RSpec.describe "PR376 independent review edges" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company), pay_rate: 15) }
  let(:actor) { create(:user, company: company, role: "admin") }
  def period(date, status: "committed")
    create(:pay_period, company: company, start_date: "2024-01-01", end_date: "2024-01-14", pay_date: date, status: status)
  end
  def calc(period, gross, tips: 0)
    item = period.payroll_items.build(employee: employee, company: company, employment_type: "hourly", pay_rate: 15,
      hours_worked: 0, bonus: gross.to_d - tips.to_d, reported_tips: tips)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    item
  end
  it "does not hold ordinary payroll for an explicitly excluded verified-empty legacy row" do
    calc(period("2024-01-19"), 1000)
    empty = create(:payroll_item, company: company, employee: employee, pay_period: period("2024-02-02"),
      hours_worked: 0, gross_pay: 0, net_pay: 0, withholding_tax: 0, social_security_tax: 0, medicare_tax: 0,
      tax_rule_snapshot: {})
    expect(PayrollItemActivity.classify(empty)).to eq(:verified_empty)
    PayrollItemLegacyDisposition.create!(payroll_item: empty, company: company, created_by: actor,
      reason: PayrollItemLegacyDisposition::REASON, evidence_digest: "a" * 64)
    expect(PayrollItem.financially_reportable.reportable.where(id: empty.id)).to be_empty
    puts "EMPTY row=#{empty.id} actual annual ids=#{EmployeeYearFicaContext.reportable_items(employee: employee, year: 2024).pluck(:id)} bases=#{empty.attributes.slice('social_security_taxable_wages', 'social_security_taxable_tips', 'additional_medicare_taxable_wages')} disposition=#{empty.legacy_disposition.reason}"
    historical = empty.reload.attributes
    run = period("2024-02-16", status: "calculated")
    item = calc(run, 75)
    batch = EmployeeYearFicaContext.batch(company: company, employees: [ employee ], year: 2024, excluding_pay_period_id: run.id)
    expect(batch.fetch(employee.id).snapshot).to eq(EmployeeYearFicaContext.new(employee: employee, year: 2024, excluding_pay_period_id: run.id).snapshot)
    lifecycle = PayPeriodLifecycleService.new(pay_period: run, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    expect(item.reload.social_security_tax).to eq("4.65".to_d)
    expect(run.reload).to be_committed
    expect(empty.reload.attributes).to eq(historical)
  end
end
