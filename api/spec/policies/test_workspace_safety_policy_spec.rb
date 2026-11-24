# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestWorkspaceSafetyPolicy do
  %w[aire_payroll_cockpits aire_manual_allocations time_tracking_calendars time_tracking_sources].each do |controller|
    it "allows local read views and blocks writes for #{controller}" do
      %w[GET HEAD POST PATCH DELETE].each do |method|
        expect(described_class.blocked?(controller_path: "api/v1/admin/#{controller}",
          action_name: "review", request_method: method)).to eq(!method.in?(%w[GET HEAD]))
      end
    end
  end

  it "blocks W-2GU Copy 1, which has full SSNs, but not the employee copies" do
    expect(described_class.blocked?(controller_path: "api/v1/admin/reports", action_name: "w2_gu_copy_1_drt", request_method: "GET")).to be(true)
    expect(described_class.blocked?(controller_path: "api/v1/admin/reports", action_name: "w2_gu_employee_copies", request_method: "GET")).to be(false)
  end

  it "gives W-2GU Copy 1 the W-2 sign-off's capability" do
    expect(StaffRolePolicy.capability_for(controller_path: "api/v1/admin/reports", action_name: "w2_gu_copy_1_drt"))
      .to eq(StaffRolePolicy.capability_for(controller_path: "api/v1/admin/reports", action_name: "w2_gu_mark_ready"))
    expect(StaffRolePolicy.capability_for(controller_path: "api/v1/admin/reports", action_name: "w2_gu_employee_copies")).to be_nil
  end

  it "blocks organization-wide placeholder email changes in test workspaces while allowing company-local report/clear" do
    expect(described_class.blocked?(controller_path: "api/v1/admin/employee_contact_hygiene", action_name: "mark_placeholder_email", request_method: "POST")).to be(true)
    expect(described_class.blocked?(controller_path: "api/v1/admin/employee_contact_hygiene", action_name: "unmark_placeholder_email", request_method: "DELETE")).to be(true)
    expect(described_class.blocked?(controller_path: "api/v1/admin/employee_contact_hygiene", action_name: "shared_emails", request_method: "GET")).to be(false)
    expect(described_class.blocked?(controller_path: "api/v1/admin/employee_contact_hygiene", action_name: "clear_shared_emails", request_method: "POST")).to be(false)
  end
end
