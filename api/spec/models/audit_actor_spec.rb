# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditActor do
  it "snapshots staff and client identities without changing their roles" do
    staff = create(:user, role: :accountant)
    client = create(:user, role: :client)

    expect(described_class.for_user(staff)).to have_attributes(
      type: "staff_user", id: staff.id.to_s, name: staff.name, email: staff.email, role: "accountant"
    )
    expect(described_class.for_user(client)).to have_attributes(type: "client_user", role: "client")
  end

  it "classifies an employee-role user as an employee" do
    user = create(:user, role: :employee)

    expect(described_class.for_user(user)).to have_attributes(type: "employee", id: user.id.to_s, role: "employee")
  end

  it "identifies employees and kiosks without a User" do
    employee = create(:employee)

    expect(described_class.employee(employee)).to have_attributes(
      type: "employee", id: employee.id.to_s, name: employee.full_name
    )
    expect(described_class.kiosk(id: "k-12", name: nil)).to have_attributes(
      type: "kiosk", id: "k-12", name: "Kiosk (k-12)"
    )
  end

  it "identifies jobs by class and execution and operators by name" do
    job = ExpirePracticePortalAccessJob.new
    expect(described_class.system_job(job)).to have_attributes(
      type: "system_job", id: job.job_id, name: "ExpirePracticePortalAccessJob"
    )
    expect(described_class.operator("Release operator")).to have_attributes(type: "operator", name: "Release operator")
  end

  it "identifies AIRE integrations and upstream workers" do
    source = create(:time_tracking_source, source_type: "aire_services")

    expect(described_class.source_system(source: source)).to have_attributes(
      type: "source_system", id: source.id.to_s, name: "AIRE System"
    )
    expect(described_class.source_worker(id: "worker-1")).to have_attributes(
      type: "source_worker", id: "worker-1", name: "AIRE Worker (worker-1)"
    )
  end
end
