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

  it "blocks delivery changes for duplicate-linked checks before the protected database trigger is reached" do
    allow(item).to receive(:duplicate_check_linked?).and_return(true)
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(eligible: false, reason: /duplicate check/)
    expect { switch_to("direct_deposit") }.to raise_error(described_class::Error, /duplicate check/)
    expect(item.reload.check_number).to eq("2000")
    expect(item.check_events).to be_empty
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

RSpec.describe 'Audited payment delivery changes' do
  let(:company) { create(:company, next_check_number: 9001) }
  let(:employee) { create(:employee, company: company, payment_delivery_method: 'paper_check') }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, :with_check, employee: employee, company: company, pay_period: period, payment_delivery_method: 'paper_check', check_number: '9000') }

  def perform_change(**options)
    PayrollPaymentMethodService.new(payroll_item: item, method: 'direct_deposit', actor: actor,
      reason: 'Confirmed with payroll manager', confirm_not_paid: true, **options).call
  end

  def cancellation
    { retire_existing_check: true, confirm_check_cancelled: true,
      cancellation_evidence_reference: 'Bank stop-payment confirmation 123', expected_check_number: '9000' }
  end

  def retain_print_package(number, include_key: true)
    entry = { 'source_type' => 'payroll_item', 'source_id' => item.id, 'check_number' => number }
    entry['key'] = "payroll_item:#{item.id}" if include_key
    period.check_print_runs.create!(company: company, created_by: actor,
      check_stock_type: 'standard', storage_key: "synthetic-#{SecureRandom.uuid}",
      filename: 'synthetic-check.pdf', sha256: 'a' * 64, byte_size: 100, selected_count: 1, generated_at: Time.current,
      manifest: [ entry ])
  end

  it 'does not require cancelling a newly assigned unprinted check because an older number had activity' do
    item.mark_package_prepared!(user: actor)
    retain_print_package('9000')
    perform_change(**cancellation)
    PayrollPaymentMethodService.new(payroll_item: item, method: 'paper_check', actor: actor,
      reason: 'Bank enrollment still pending', confirm_not_paid: true, expected_check_number: nil).call
    expect(item.reload.check_number).to eq('9001')
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(mode: 'simple', requires_check_cancellation: false)
    perform_change(expected_check_number: '9001')
    expect(item.reload.check_number).to be_nil
    expect(item.check_events.where(event_type: 'voided').pluck(:check_number)).to contain_exactly('9000', '9001')
  end

  it 'still protects a current check present in a retained package without preparation markers' do
    retain_print_package('9000')
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(mode: 'retire_check')
    expect { perform_change }.to raise_error(PayrollPaymentMethodService::Error, /simple switch/)
  end

  it 'conservatively protects legacy package entries that lack a check number' do
    retain_print_package(nil, include_key: false)
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(mode: 'retire_check')
    expect { perform_change }.to raise_error(PayrollPaymentMethodService::Error, /simple switch/)
  end

  it 'rejects an explicit expected absence after another accountant assigns a check' do
    expect { perform_change(expected_check_number: nil, update_employee_default: true) }
      .to raise_error(PayrollPaymentMethodService::Error, /number changed/)
    expect(item.reload).to have_attributes(check_number: '9000', payment_delivery_method: 'paper_check')
    expect(employee.reload.payment_delivery_method).to eq('paper_check')
  end

  it 'retires a prepared check with explicit evidence without changing money or voiding payroll' do
    item.mark_package_prepared!(user: actor)
    money = item.attributes.slice('gross_pay', 'net_pay', 'withholding_tax', 'social_security_tax', 'medicare_tax', 'loan_payment')
    expect(PayrollCalculator).not_to receive(:for)
    expect { perform_change(**cancellation) }.not_to change(company.reload, :next_check_number)
    expect(item.reload.attributes.slice(*money.keys)).to eq(money)
    expect(item).to have_attributes(payment_delivery_method: 'direct_deposit', check_number: nil,
      voided: false, check_prepared_at: nil, check_printed_at: nil)
    event = item.check_events.find_by!(event_type: 'voided', check_number: '9000')
    expect(event.evidence_reference).to eq(cancellation[:cancellation_evidence_reference])
    expect(event.details).to include('original_check_cancelled' => true)
    expect(item.check_events.where(event_type: 'prepared')).to exist
  end

  it 'keeps the simple switch protection and advertises retirement explicitly' do
    item.mark_package_prepared!(user: actor)
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(mode: 'retire_check', requires_check_cancellation: true)
    expect { perform_change }.to raise_error(PayrollPaymentMethodService::Error, /simple switch/)
  end

  it 'refuses retirement without cancellation confirmation or a recorded reference' do
    item.mark_package_prepared!(user: actor)
    expect { perform_change(**cancellation.merge(confirm_check_cancelled: false)) }.to raise_error(PayrollPaymentMethodService::Error, /evidence/)
    expect { perform_change(**cancellation.merge(cancellation_evidence_reference: '')) }.to raise_error(PayrollPaymentMethodService::Error, /evidence/)
    expect(item.reload.check_number).to eq('9000')
  end

  it 'refuses retirement of a concurrently replaced check' do
    item.update!(check_number: '9002')
    expect { perform_change(**cancellation) }.to raise_error(PayrollPaymentMethodService::Error, /number changed/)
    expect(item.reload.payment_delivery_method).to eq('paper_check')
  end

  it 'never retires a cleared check even with cancellation attestation' do
    company.check_reconciliation_events.create!(pay_period: period, payroll_item: item, recorded_by: actor,
      event_type: 'cleared', check_number: item.check_number, amount: item.net_pay,
      effective_on: PayrollBusinessClock.today, evidence_type: 'bank_portal', evidence_reference: 'Bank transaction 88', idempotency_key: SecureRandom.uuid)
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(eligible: false, mode: 'blocked')
    expect { perform_change(**cancellation) }.to raise_error(PayrollPaymentMethodService::Error, /cleared/)
  end

  %w[printed batch_downloaded delivered].each do |event_type|
    it "requires cancellation evidence after #{event_type} activity" do
      item.check_events.create!(user: actor, event_type: event_type, check_number: '9000')
      expect { perform_change }.to raise_error(PayrollPaymentMethodService::Error, /simple switch/)
      perform_change(**cancellation)
      expect(item.reload).not_to be_voided
    end
  end

  it 'treats historical prepared packages as protected even when row timestamps are absent' do
    item.check_events.create!(user: actor, event_type: 'prepared', check_number: '9000')
    expect { perform_change }.to raise_error(PayrollPaymentMethodService::Error, /simple switch/)
  end

  [ 0, -10 ].each do |net|
    it "never assigns a check number to a #{net} net direct-deposit statement" do
      item.update!(payment_delivery_method: 'direct_deposit', check_number: nil, net_pay: net)
      expect(PayrollPaymentMethodEligibility.new(item).call).to include(eligible: false, mode: 'blocked')
      expect {
        PayrollPaymentMethodService.new(payroll_item: item, method: 'paper_check', actor: actor,
          reason: 'Payment method requested', confirm_not_paid: true).call
      }.to raise_error(PayrollPaymentMethodService::Error, /no net payment/)
      expect(item.reload.check_number).to be_nil
      expect(company.reload.next_check_number).to eq(9001)
    end
  end

  it 'updates the future default even when this run already uses the requested method' do
    item.update!(payment_delivery_method: 'direct_deposit', check_number: nil)
    perform_change(update_employee_default: true)
    expect(employee.reload.payment_delivery_method).to eq('direct_deposit')
    expect(company.reload.next_check_number).to eq(9001)
  end

  it 'atomically rolls back run and default when the employee default cannot save' do
    allow_any_instance_of(EmployeePaymentDefaultService).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(employee))
    expect { perform_change(update_employee_default: true) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(item.reload).to have_attributes(payment_delivery_method: 'paper_check', check_number: '9000')
    expect(employee.reload.payment_delivery_method).to eq('paper_check')
    expect(item.check_events).to be_empty
  end

  it 'rolls approved runs back for fresh review without changing calculated amounts' do
    period.update!(status: 'approved', approved_by_id: actor.id, approved_at: Time.current)
    item.update!(check_number: nil)
    original_net = item.net_pay
    perform_change(update_employee_default: true)
    expect(period.reload).to have_attributes(status: 'calculated', approved_by_id: nil, approved_at: nil)
    expect(period.payroll_review_packages.current.last).to be_pending
    expect(item.reload.net_pay).to eq(original_net)
  end
end
