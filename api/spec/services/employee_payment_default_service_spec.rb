# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmployeePaymentDefaultService do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, payment_delivery_method: 'paper_check') }
  let(:actor) { create(:user, company: company, organization: company.organization) }

  def change_default(method = 'direct_deposit')
    described_class.new(employee: employee, method: method, actor: actor).call
  end

  it 'preserves an inherited reviewed method and supersedes approval for its explicit snapshot' do
    period = create(:pay_period, company: company, status: 'calculated')
    item = create(:payroll_item, employee: employee, pay_period: period, payment_delivery_method: nil, net_pay: 500)
    old_review = PayrollReview::RevisionService.new(pay_period: period, actor: actor).issue!
    period.update!(status: 'approved', approved_at: Time.current, approved_by_id: actor.id)
    default_service = described_class.new(employee: employee, method: 'direct_deposit', actor: actor)
    default_service.call
    expect(item.reload.payment_delivery_method).to eq('paper_check')
    expect(employee.reload.payment_delivery_method).to eq('direct_deposit')
    expect(period.reload).to have_attributes(status: 'calculated', approved_by_id: nil)
    expect(old_review.reload).to be_superseded
    expect(period.payroll_review_packages.current.last).to be_pending
    expect(default_service.reapproval_pay_period_ids).to eq([ period.id ])
  end

  it 'preserves committed history and existing explicit uncommitted choices' do
    history = create(:pay_period, :committed, company: company)
    history_item = create(:payroll_item, employee: employee, pay_period: history, payment_delivery_method: nil)
    draft = create(:pay_period, company: company)
    explicit_item = create(:payroll_item, employee: employee, pay_period: draft, payment_delivery_method: 'paper_check')
    change_default
    expect(history_item.reload.payment_delivery_method).to be_nil
    expect(history_item.effective_payment_delivery_method).to eq('paper_check')
    expect(explicit_item.reload.payment_delivery_method).to eq('paper_check')
  end

  it 'freezes inherited zero-net rows without allocating a check number' do
    period = create(:pay_period, company: company)
    item = create(:payroll_item, employee: employee, pay_period: period, payment_delivery_method: nil, net_pay: 0)
    change_default
    expect(item.reload).to have_attributes(payment_delivery_method: 'paper_check', check_number: nil)
  end

  it 'rolls all preservation back when the new default is invalid' do
    period = create(:pay_period, company: company)
    item = create(:payroll_item, employee: employee, pay_period: period, payment_delivery_method: nil)
    expect { change_default('invalid') }.to raise_error(ActiveRecord::RecordInvalid)
    expect(item.reload.payment_delivery_method).to be_nil
    expect(employee.reload.payment_delivery_method).to eq('paper_check')
  end
end
