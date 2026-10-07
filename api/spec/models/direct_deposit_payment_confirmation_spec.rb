# frozen_string_literal: true

require "rails_helper"

RSpec.describe DirectDepositPaymentConfirmation do
  it "issues separate exact payable lines for one source entry and preserves bank evidence" do
    company = create(:company)
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    employee = create(:employee, company: company, department: create(:department, company: company))
    period = create(:pay_period, :committed, company: company)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period,
      payment_delivery_method: "direct_deposit", check_number: nil, net_pay: 100)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source)
    uuid = SecureRandom.uuid
    %w[category:1 category:2].each do |key|
      TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source, time_tracking_import: import,
        pay_period: period, payroll_item: item, employee: employee, source_user_id: "91", source_user_uuid: uuid,
        source_time_entry_id: "41", original_work_date: period.start_date, line_key: key, source_kind: "current",
        total_hours: 2, regular_hours: 2, overtime_hours: 0)
    end
    confirmation = item.create_direct_deposit_payment_confirmation!(user: actor,
      settled_on: PayrollBusinessClock.today, bank_reference: "TEST-BANK-REFERENCE")
    events = item.aire_payroll_entry_acknowledgements.where(status: "payment_issued")
    expect(events.pluck(:source_line_key).sort).to eq(%w[category:1 category:2])
    expect(events.pluck(:payment_effective_on).uniq).to eq([ PayrollBusinessClock.today ])
    expect(events.pluck(:payment_reference).uniq).to eq([ "TEST-BANK-REFERENCE" ])
    expect { confirmation.update!(bank_reference: "changed") }.to raise_error(ActiveRecord::RecordNotSaved)
    expect { DirectDepositPaymentConfirmation.where(id: confirmation.id).update_all(bank_reference: "changed") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
  it "rejects a bank reference the connected payment protocol cannot retain before recording a payment" do
    company = create(:company)
    actor = create(:user, company: company, organization: company.organization)
    employee = create(:employee, company: company)
    period = create(:pay_period, :committed, company: company)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period,
      payment_delivery_method: "direct_deposit", check_number: nil, net_pay: 100)
    expect {
      expect {
        item.create_direct_deposit_payment_confirmation!(user: actor,
          settled_on: PayrollBusinessClock.today, bank_reference: "x" * 201)
      }.to raise_error(ActiveRecord::RecordInvalid, /too long/)
    }.not_to change(DirectDepositPaymentConfirmation, :count)
    expect(item.reload.direct_deposit_payment_confirmation).to be_nil
    expect(item.aire_payroll_entry_acknowledgements).to be_empty
    expect(item.net_pay).to eq(100)
  end

end
