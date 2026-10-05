# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeePayrollPaymentEvidence do
  let(:period) { create(:pay_period, :committed) }
  let(:employee) { create(:employee, company: period.company) }
  let(:user) { create(:user, company: period.company) }
  let(:item) { create(:payroll_item, :printed, employee: employee, pay_period: period) }

  it "does not call a printed check issued without delivery evidence" do
    expect(described_class.new(item).call[:status]).to eq("printed")
  end

  it "does not count delivery of an older check number as delivery of its replacement" do
    create(:check_event, payroll_item: item, user: user, event_type: "delivered", check_number: "OLD", effective_on: Date.current)
    expect(described_class.new(item.reload).call[:status]).to eq("printed")
  end

  it "reports current-number delivery and the original effective date" do
    create(:check_event, payroll_item: item, user: user, event_type: "delivered", effective_on: Date.current)
    expect(described_class.new(item.reload).call).to include(status: "issued", effective_on: Date.current)
  end

  it "never counts a voided paycheck as issued" do
    create(:check_event, payroll_item: item, user: user, event_type: "delivered", effective_on: Date.current)
    item.update_columns(voided: true)
    expect(described_class.new(item.reload).call[:status]).to eq("voided")
  end

  it "requires an external confirmation for a direct deposit" do
    item.update!(payment_delivery_method: "direct_deposit", check_number: nil)
    expect(described_class.new(item).call[:status]).to eq("unissued")
    user = create(:user, company: period.company)
    item.create_direct_deposit_payment_confirmation!(user: user, bank_reference: "BANK-123", settled_on: Date.current)
    expect(described_class.new(item.reload).call).to include(status: "issued", label: "Transfer confirmed", effective_on: Date.current)
  end
end
