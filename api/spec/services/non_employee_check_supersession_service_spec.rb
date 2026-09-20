require "rails_helper"

RSpec.describe NonEmployeeCheckSupersessionService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company) }
  let(:period) do
    create(:pay_period, :committed, company: company,
           start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 15), pay_date: Date.new(2026, 5, 19))
  end
  let(:item) do
    create(:payroll_item, :printed, company: company, pay_period: period, employee: employee,
           check_number: "01045", net_pay: 183, payment_delivery_method: "paper_check")
  end
  let(:check) do
    create(:non_employee_check, :standalone, company: company, check_type: "other",
           payment_period_type: "none", tax_year: nil, tax_month: nil,
           payable_to: employee.full_name, amount: 183, check_number: "1045",
           printed_at: Time.current, payment_method: "check")
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("LIVE_CHECK_SUPERSESSION_APPROVED_COMPANY_IDS", "").and_return(company.id.to_s)
  end

  it "links matching printed records without deleting the standalone evidence" do
    item
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    service = described_class.new(check: check, actor: actor)
    expect(service.candidates).to contain_exactly(item)
    evidence = service.supersede!(payroll_item_id: item.id, reason: "Same issued physical check verified against payroll item", recipient_verified: true)

    expect(evidence.payroll_item).to eq(item)
    expect(evidence.verified_facts).to include("standalone_payee" => employee.full_name,
                                               "payroll_employee_name" => employee.full_name,
                                               "normalized_check_number" => "1045",
                                               "recipient_verified" => true)
    expect(evidence.verified_facts.fetch("delivery_event_id")).to be_present
    expect(check.reload.check_status).to eq("superseded")
    expect(NonEmployeeCheck.active).not_to include(check)
    expect(check).to be_persisted
    register = CheckRegisterService.new(company: company, from: "2026-05-01", to: "2026-05-31").call
    expect(register.fetch(:rows).map { |row| row.fetch(:source_type) }).to eq([ "payroll_item" ])
    expect(register.dig(:summary, :amount)).to eq(183.to_d)
    expect(evidence.update(reason: "Changed reason")).to eq(false)
    expect { NonEmployeeCheckSupersession.where(id: evidence.id).update_all(reason: "Changed reason") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "rejects mismatched numbers and does not double count" do
    item.update!(check_number: "1046")
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    service = described_class.new(check: check, actor: actor)
    expect(service.candidates).to be_empty
    expect { service.supersede!(payroll_item_id: item.id, reason: "Same issued physical check verified against payroll item", recipient_verified: true) }
      .to raise_error(described_class::Error)
    expect(NonEmployeeCheckSupersession.count).to eq(0)
  end

  it "does not allow the same duplicate to be linked twice" do
    item
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    service = described_class.new(check: check, actor: actor)
    service.supersede!(payroll_item_id: item.id, reason: "Same issued physical check verified against payroll item", recipient_verified: true)
    expect { service.supersede!(payroll_item_id: item.id, reason: "Repeated duplicate link must be rejected", recipient_verified: true) }
      .to raise_error(described_class::Error)
  end

  it "does not hide a prepared payroll check that has no delivery evidence" do
    item
    expect(described_class.new(check: check, actor: actor).candidates).to be_empty
  end

  it "rechecks the payroll item after locking when it changes during review" do
    item
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    allow_any_instance_of(PayrollItem).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      original.receiver.update_columns(voided: true, voided_at: Time.current)
      original.call(*args, &block)
    end

    expect { described_class.new(check: check, actor: actor).supersede!(
      payroll_item_id: item.id, reason: "Same issued physical check verified against payroll item", recipient_verified: true) }
      .to raise_error(described_class::Error, /matching issued payroll check/)
    expect(NonEmployeeCheckSupersession.count).to eq(0)
  end

  it "requires an explicit recipient attestation even when check number and amount match" do
    item
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    expect { described_class.new(check: check, actor: actor).supersede!(
      payroll_item_id: item.id, reason: "Same issued physical check verified against payroll item", recipient_verified: false) }
      .to raise_error(described_class::Error, /recipient/)
    expect(NonEmployeeCheckSupersession.count).to eq(0)
  end

  it "blocks live-company reconciliation until that company is explicitly enabled" do
    item
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    allow(ENV).to receive(:fetch).with("LIVE_CHECK_SUPERSESSION_APPROVED_COMPANY_IDS", "").and_return("")
    expect { described_class.new(check: check, actor: actor).supersede!(
      payroll_item_id: item.id, reason: "Same issued physical check verified against payroll item", recipient_verified: true) }
      .to raise_error(described_class::Error, /disabled/)
    expect(NonEmployeeCheckSupersession.count).to eq(0)
  end

  it "rejects cross-company evidence at the database boundary" do
    item
    other_company = create(:company, organization: company.organization)
    other_item = create(:payroll_item, company: other_company, employee: create(:employee, company: other_company),
                       pay_period: create(:pay_period, :committed, company: other_company))
    expect { NonEmployeeCheckSupersession.insert_all!([ {
      non_employee_check_id: check.id, payroll_item_id: other_item.id, company_id: company.id,
      user_id: actor.id, reason: "This would incorrectly hide another company's check",
      verified_facts: { recipient_verified: true }, created_at: Time.current
    } ]) }.to raise_error(ActiveRecord::StatementInvalid, /same company/)
  end
end
