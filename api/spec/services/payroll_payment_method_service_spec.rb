# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollPaymentMethodService do
  let(:company) { create(:company, next_check_number: 2001) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) do
    create(:payroll_item, pay_period: period, company: company, employee: employee,
      payment_delivery_method: "paper_check", check_number: "2000", gross_pay: 600, net_pay: 500)
  end

  def switch_to(method, reason: "Confirmed no payment issued", confirm_not_paid: true)
    described_class.new(
      payroll_item: item, method: method, actor: actor,
      reason: reason, confirm_not_paid: confirm_not_paid
    ).call
  end

  it "retires an unissued check, retains its event history, and does not change payroll money" do
    before_net = item.net_pay

    switch_to("direct_deposit")

    expect(item.reload).to have_attributes(
      payment_delivery_method: "direct_deposit", check_number: nil, net_pay: before_net
    )
    expect(item.check_events.where(event_type: "voided", check_number: "2000")).to exist
    expect(AuditLog.where(record_type: "PayrollItem", record_id: item.id, action: "payroll_item#payment_delivery_method_changed")).to exist
    expect(company.reload.next_check_number).to eq(2001)
  end

  it "assigns a fresh check number when an unissued direct deposit becomes paper" do
    item.update!(payment_delivery_method: "direct_deposit", check_number: nil)

    switch_to("paper_check")

    expect(item.reload).to have_attributes(payment_delivery_method: "paper_check", check_number: "2001")
    expect(item.check_events.where(event_type: "assigned", check_number: "2001")).to exist
    expect(company.reload.next_check_number).to eq(2002)
  end

  it "refuses to switch a check after it was printed" do
    item.update!(check_printed_at: Time.current)

    expect { switch_to("direct_deposit") }.to raise_error(described_class::Error, /printed/)
    expect(item.reload.check_number).to eq("2000")
  end

  it "requires a reason and no-payment attestation after commitment" do
    expect { switch_to("direct_deposit", reason: "short") }.to raise_error(described_class::Error, /reason/)
    expect { switch_to("direct_deposit", confirm_not_paid: false) }.to raise_error(described_class::Error, /Confirm/)
  end

  it "changes a calculated run without changing its payroll math or future employee default" do
    calculated_period = create(:pay_period, :calculated, company: company)
    calculated_item = create(:payroll_item, pay_period: calculated_period, company: company,
      employee: employee, payment_delivery_method: "paper_check", gross_pay: 600, net_pay: 500)

    described_class.new(payroll_item: calculated_item, method: "direct_deposit", actor: actor).call

    expect(calculated_period.reload).to be_calculated
    expect(calculated_item.reload).to have_attributes(payment_delivery_method: "direct_deposit", gross_pay: 600, net_pay: 500)
    expect(employee.reload.payment_delivery_method).to be_nil
  end
end
