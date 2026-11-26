# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127010000_add_superseded_status_to_employee_change_requests")

RSpec.describe AddSupersededStatusToEmployeeChangeRequests do
  let(:connection) { ActiveRecord::Base.connection }

  def constraint?
    connection.check_constraint_exists?(:employee_change_requests, name: "employee_change_requests_status_check")
  end

  it "rolls superseded requests back to cancelled and drops the constraint, then restores it" do
    company = create(:company)
    requester = create(:user, company: company)
    superseded = create(:employee_change_request, company: company, employee: create(:employee, company: company),
      requested_by: requester, status: :superseded)
    pending = create(:employee_change_request, company: company, employee: create(:employee, company: company), requested_by: requester)

    described_class.new.migrate(:down)
    expect(constraint?).to be(false)
    expect(superseded.reload).to be_cancelled
    expect(pending.reload).to be_pending

    described_class.new.migrate(:up)
    expect(constraint?).to be(true)
    expect { connection.execute("UPDATE employee_change_requests SET status = 9 WHERE id = #{pending.id}") }
      .to raise_error(ActiveRecord::StatementInvalid, /employee_change_requests_status_check/)
  end
end
