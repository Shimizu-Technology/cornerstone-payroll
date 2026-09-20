require "rails_helper"

RSpec.describe NonEmployeeCheckSupersessionService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:approver) { create(:user, company: company, role: "org_admin") }
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
  let(:delivery) do
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
  end
  let(:verified_facts) do
    {
      "standalone_payee" => check.payable_to,
      "payroll_employee_id" => employee.id,
      "payroll_employee_name" => employee.full_name,
      "standalone_check_number" => check.check_number,
      "payroll_check_number" => item.check_number,
      "normalized_check_number" => "1045",
      "standalone_amount" => check.amount.to_s,
      "payroll_net_amount" => item.net_pay.to_s,
      "delivery_event_id" => delivery.id,
      "delivered_on" => delivery.effective_on.iso8601,
      "delivery_evidence_type" => delivery.evidence_type,
      "delivery_evidence_reference" => delivery.evidence_reference,
      "recipient_verified" => true
    }
  end
  let(:raw_record) do
    { non_employee_check_id: check.id, payroll_item_id: item.id, company_id: company.id,
      user_id: actor.id, reason: "One physical check verified against payroll item",
      verified_facts: verified_facts, created_at: Time.current }
  end

  before do
    unless RSpec.current_example.metadata[:unapproved]
      CheckSupersessionRolloutApproval.create!(company: company, approved_by: approver,
                                               reason: "Approved for isolated reconciliation test only",
                                               approved_at: Time.current)
    end
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

  it "keeps exactly one active payment when someone tries to void the linked payroll check" do
    item
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    described_class.new(check: check, actor: actor).supersede!(
      payroll_item_id: item.id, reason: "Same issued physical check verified against payroll item", recipient_verified: true)

    expect { item.void!(user: actor, reason: "This check should not be voided") }
      .to raise_error(ArgumentError, /linked to a duplicate/)
    expect {
      ApplicationRecord.transaction(requires_new: true) do
        PayrollItem.where(id: item.id).update_all(voided: true)
      end
    }.to raise_error(ActiveRecord::StatementInvalid, /linked to a duplicate/)

    expect(item.reload.voided?).to eq(false)
    expect(NonEmployeeCheck.active).not_to include(check)
    register = CheckRegisterService.new(company: company, from: "2026-05-01", to: "2026-05-31").call
    expect(register.fetch(:rows).map { |row| row.fetch(:source_type) }).to eq([ "payroll_item" ])
    expect(register.dig(:summary, :amount)).to eq(183.to_d)
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

  it "blocks live-company reconciliation until that company is explicitly enabled", :unapproved do
    item
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
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
    } ]) }.to raise_error(ActiveRecord::StatementInvalid, /matching company/)
  end

  it "rejects a direct insert with missing verified facts" do
    expect { NonEmployeeCheckSupersession.insert_all!([ raw_record.merge(verified_facts: {}) ]) }
      .to raise_error(ActiveRecord::StatementInvalid, /recipient attestation/)
  end

  it "rejects a direct insert with a mismatched amount snapshot" do
    expect { NonEmployeeCheckSupersession.insert_all!([ raw_record.merge(
      verified_facts: verified_facts.merge("standalone_amount" => "999.00")
    ) ]) }.to raise_error(ActiveRecord::StatementInvalid, /amount/)
  end

  it "rejects a direct insert without the matching delivery event" do
    expect { NonEmployeeCheckSupersession.insert_all!([ raw_record.merge(
      verified_facts: verified_facts.merge("delivery_event_id" => 0)
    ) ]) }.to raise_error(ActiveRecord::StatementInvalid, /delivery evidence/)
  end

  it "rejects a direct insert for an unapproved live company", :unapproved do
    expect { NonEmployeeCheckSupersession.insert_all!([ raw_record ]) }
      .to raise_error(ActiveRecord::StatementInvalid, /rollout approval/)
  end

  it "rejects a direct insert from an unauthorized reviewer" do
    accountant = create(:user, company: company, role: "accountant")
    expect { NonEmployeeCheckSupersession.insert_all!([ raw_record.merge(user_id: accountant.id) ]) }
      .to raise_error(ActiveRecord::StatementInvalid, /manager or administrator/)
  end

  it "rejects a direct rollout approval from a non-administrator", :unapproved do
    accountant = create(:user, company: company, role: "accountant")
    expect { CheckSupersessionRolloutApproval.insert_all!([ {
      company_id: company.id, approved_by_id: accountant.id,
      reason: "Unauthorized approval must never enable a live company",
      approved_at: Time.current, created_at: Time.current
    } ]) }.to raise_error(ActiveRecord::StatementInvalid, /administrator/)
  end
end
