# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe EmployeePlaceholderEmail, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Placeholder lock #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, name: "Placeholder lock #{SecureRandom.hex(4)}") }
  let!(:staff) { create(:user, company: company, organization: organization, role: "org_admin") }

  after do
    TenantScope.as_system(reason: "Clean placeholder lock spec") do
      AuditLog.where(organization_id: organization.id).delete_all
      described_class.where(organization_id: organization.id).delete_all
      User.where(id: staff.id).delete_all
      Company.where(id: company.id).delete_all
      Organization.where(id: organization.id).delete_all
    end
  end

  def mark!(email)
    EmployeeContactHygiene::PlaceholderEmailService.new(organization: organization, email: email, actor: staff, company: company).mark!
  end

  it "makes a mark wait while a history approval holds the organization's placeholder lock, then applies it" do
    approval_locked = Queue.new
    release_approval = Queue.new
    # Stands in for TimeTracking::HistoryApproval#with_approval_locks, which
    # takes this shared lock before its locked refresh and holds it to commit.
    approval = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.transaction do
          described_class.lock_organization!(organization.id, shared: true)
          approval_locked << true
          release_approval.pop
        end
      end
    end
    Timeout.timeout(10) { approval_locked.pop }

    marker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantScope.as_system(reason: "Mark a placeholder during an approval") { mark!("late-mark@example.com") }
      end
    end

    expect(marker.join(0.5)).to be_nil
    expect(described_class.where(organization_id: organization.id).count).to eq(0)

    release_approval << true
    Timeout.timeout(10) { [ approval, marker ].each(&:join) }
    expect(marker.value).to have_attributes(marked: true, changed: true)
    expect(described_class.where(organization_id: organization.id).pluck(:email)).to eq([ "late-mark@example.com" ])
  end

  it "lets approvals in the same organization read the marks together" do
    both_locked = Queue.new
    release = Queue.new
    holders = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.transaction do
            described_class.lock_organization!(organization.id, shared: true)
            both_locked << true
            release.pop
          end
        end
      end
    end
    # Both shared holders get the lock at the same time.
    Timeout.timeout(5) { 2.times { both_locked.pop } }
    2.times { release << true }
    Timeout.timeout(10) { holders.each(&:join) }
  end
end
