# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll commit snapshots", type: :model do
  let(:company) { create(:company, next_check_number: 5000, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:run) { create(:pay_period, company: company, status: "approved") }
  let!(:item) { create(:payroll_item, company: company, pay_period: run, employee: create(:employee, company: company), gross_pay: 1200, net_pay: 1100) }
  let(:period) { PayrollSubmissionPeriod.create!(company: company, start_date: run.start_date, end_date: run.end_date, source: "pay_period") }
  let(:request) do
    PortalFileRequest.create!(company: company, payroll_submission_period: period, title: "Signed timesheet", category: "payroll_source",
      client_portal_thread: create(:client_portal_thread, company: company), requested_by: actor, status: "requested")
  end
  let(:service) { PayPeriodLifecycleService.new(pay_period: run, actor: actor) }

  before { ensure_verified_test_tax_years(run.pay_date.year) }

  it "commits only the exact outstanding set and retains its audit evidence" do
    expect { service.commit!(acknowledged_outstanding_file_request_ids: [ request.id ], expected_next_check_number: 5000) }.to change { run.reload.status }.to("committed")
    expect(service.acknowledged_outstanding_file_requests).to eq([ { id: request.id, title: request.title, status: "requested" } ])
    expect(item.reload.check_number).to eq("5000")
    expect(request.reload).to be_outstanding
  end

  it "rejects both newly outstanding and newly resolved requests without changing payroll" do
    id = request.id
    expect { service.commit!(acknowledged_outstanding_file_request_ids: []) }.to raise_error(PayPeriodLifecycleService::CommitConflict) { |e| expect(e.code).to eq("outstanding_file_requests_changed") }
    request.update!(status: "withdrawn", resolved_by: actor, resolved_at: Time.current)
    expect { service.commit!(acknowledged_outstanding_file_request_ids: [ id ]) }.to raise_error(PayPeriodLifecycleService::CommitConflict)
    expect(run.reload).to be_approved
    expect(item.reload.check_number).to be_nil
    expect(company.reload.next_check_number).to eq(5000)
  end

  it "rejects stale numbering even when the service's company association was already loaded" do
    run.company.next_check_number
    Company.find(company.id).update!(next_check_number: 6000)
    expect { service.commit!(expected_next_check_number: 5000) }.to raise_error(PayPeriodLifecycleService::CommitConflict) { |e| expect(e.code).to eq("check_number_changed") }
    expect(run.reload).to be_approved
    service.commit!(expected_next_check_number: 6000)
    expect(item.reload.check_number).to eq("6000")
  end

  it "rejects malformed request sets and check counters" do
    [ true, "1", [ "bad" ], [ 1.5 ] ].each do |ids|
      expect { service.commit!(acknowledged_outstanding_file_request_ids: ids) }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError)
    end
    expect { service.commit!(expected_next_check_number: "5.5") }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError)
  end
end
