# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client management service delayed revocation" do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: :org_admin) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: :accountant) }
  let!(:assignment) { create(:company_assignment, user: actor, company: company, granted_by: admin, client_management: true) }
  let!(:employee) { create(:employee, company: company, pay_rate: 18) }

  it "does not append a retirement election or synchronize legacy rates after revocation during employee locking" do
    allow(employee).to receive(:lock!).and_wrap_original do |original, *args|
      assignment.update!(client_management: false)
      original.call(*args)
    end
    original_rate = employee.retirement_rate
    expect(AuditLog).not_to receive(:record!)

    expect do
      EmployeeRetirementElectionChangeService.new(employee: employee, actor: actor, source: "staff", reason: "Signed election",
        attributes: { effective_on: Date.current, participating: true, traditional_rate: 0.06 }).call!
    end.to raise_error(EmployeeRetirementElectionChangeService::Error, /Client configuration access required/)

    expect(employee.employee_retirement_elections.reload).to be_empty
    expect(employee.reload.retirement_rate).to eq(original_rate)
  end

  it "does not persist a partial retirement election if legacy synchronization fails" do
    service = EmployeeRetirementElectionChangeService.new(employee: employee, actor: actor, source: "staff", reason: "Signed election",
      attributes: { effective_on: Date.current, participating: true, traditional_rate: 0.06 })
    allow(employee).to receive(:update_columns).and_raise(ActiveRecord::StatementInvalid, "Synchronization failed")

    expect { service.call! }.to raise_error(ActiveRecord::StatementInvalid, /Synchronization failed/)
    expect(employee.employee_retirement_elections.reload).to be_empty
  end

  it "does not create immutable duplicate-check evidence after revocation during payroll item locking" do
    period = create(:pay_period, :committed, company: company)
    item = create(:payroll_item, :printed, company: company, employee: employee, pay_period: period,
      check_number: "01045", net_pay: 183, payment_delivery_method: "paper_check")
    check = create(:non_employee_check, :standalone, company: company, check_type: "other", payment_period_type: "none",
      tax_year: nil, tax_month: nil, payable_to: employee.full_name, amount: 183, check_number: "1045",
      printed_at: Time.current, payment_method: "check")
    create(:check_event, payroll_item: item, user: admin, event_type: "delivered", effective_on: PayrollBusinessClock.today)
    CheckSupersessionRolloutApproval.create!(company: company, approved_by: admin,
      reason: "Approved for isolated reconciliation test only", approved_at: Time.current)
    allow_any_instance_of(PayrollItem).to receive(:lock!).and_wrap_original do |original, *args|
      assignment.update!(client_management: false)
      original.call(*args)
    end
    expect(AuditLog).not_to receive(:record!)

    expect do
      NonEmployeeCheckSupersessionService.new(check: check, actor: actor).supersede!(payroll_item_id: item.id,
        reason: "Same physical check verified against payroll item", recipient_verified: true)
    end.to raise_error(NonEmployeeCheckSupersessionService::Error, /authorized manager/)

    expect(NonEmployeeCheckSupersession.where(non_employee_check: check)).to be_empty
    expect(check.reload).to be_persisted
    expect(item.reload).not_to be_voided
  end
end
