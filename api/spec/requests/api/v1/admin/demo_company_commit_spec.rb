# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Demo company contained commit", type: :request do
  let!(:tax_table) { create(:tax_table, tax_year: 2026) }
  let(:organization) { create(:organization) }
  let(:live) { create(:company, organization: organization, name: "Live Client") }
  let(:demo) { create_demo_company(organization: organization) }
  let(:admin) { create(:user, company: live, organization: organization, role: "admin") }
  let(:employee) do
    create(:employee, company: demo, department: create(:department, company: demo), ssn_encrypted: "900-01-2001",
      payment_delivery_method: "paper_check")
  end
  let(:period) { create(:pay_period, company: demo, start_date: Date.new(2026, 8, 2), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 21)) }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(admin.id) }
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(ApplicationController).to receive(:current_company_id) { demo.id }
    create(:payroll_item, employee: employee, company: demo, pay_period: period, hours_worked: 80, payment_delivery_method: "paper_check").calculate!
    period.update!(status: "calculated")
    PayPeriodLifecycleService.new(pay_period: period.reload, actor: admin).approve!
  end

  it "commits like a live client but posts no liability, FIT check, AIRE or filing record" do
    post "/api/v1/admin/pay_periods/#{period.id}/commit", params: { expected_next_check_number: demo.next_check_number }
    expect(response).to have_http_status(:ok), response.body

    expect(period.reload).to be_committed
    expect(PortalNotificationEvent.where(event_type: "payroll_committed", subject: period)
      .pluck(Arel.sql("metadata->>'recipient_scope'"))).to contain_exactly("client_managers", "client_viewers")
    expect(period.payroll_items.first.check_number).to be_present
    expect(EmployeeYtdTotal.where(employee: employee, year: 2026).sum(:gross_pay)).to be_positive
    expect(PayrollLiabilityPosting.where(company: demo)).to be_empty
    expect(PayrollLiabilityEntry.where(company: demo)).to be_empty
    expect(NonEmployeeCheck.where(company: demo)).to be_empty
    expect(AirePayrollAcknowledgement.count + AirePayrollEntryAcknowledgement.count).to eq(0)
    expect(PayrollFilingRecord.where(company: demo)).to be_empty

    post "/api/v1/admin/pay_periods/#{period.id}/checks/batch_pdf"
    expect(response).to have_http_status(:ok), response.body
    expect(response.media_type).to eq("application/pdf")

    post "/api/v1/admin/pay_periods/#{period.id}/generate_fit_check"
    expect(response.parsed_body.fetch("error")).to eq(Company::DEMO_UNAVAILABLE_MESSAGE)
  end

  it "voids a committed demo payroll without liability postings" do
    post "/api/v1/admin/pay_periods/#{period.id}/commit", params: { expected_next_check_number: demo.next_check_number }
    expect(response).to have_http_status(:ok), response.body
    post "/api/v1/admin/pay_periods/#{period.id}/void", params: { reason: "Entered the wrong week", unpaid_acknowledgement: true }
    expect(response).to have_http_status(:ok), response.body
    expect(period.reload.correction_status).to eq("voided")
    expect(PayrollLiabilityPosting.where(company: demo)).to be_empty
  end

  it "keeps a practice copy from committing" do
    sandbox = create(:company, organization: organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company: live, migration_rehearsal_status: "ready")
    practice_period = create(:pay_period, company: sandbox)
    practice_period.status = "committed"
    expect(practice_period).not_to be_valid
    expect(practice_period.errors[:status]).to be_present
  end
end
