# frozen_string_literal: true

require "rails_helper"

# M4-9d: a demo company served under the early-access waiver (database RLS
# not enforced yet) answers employee portal requests only while the current
# process runs the RLS guard in raise mode as the restricted role.
RSpec.describe "Employee portal demo guard", type: :request do
  include EmployeeLinkHelpers

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Alpha Grill") }
  let(:employee) { create(:employee, company: company, first_name: "Jordan", last_name: "Reyes") }
  let(:worker) { create(:user, role: :portal_employee, company: company, clerk_id: "user_jordan") }
  let!(:link) { EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active") }

  before do
    enable_employee_app!(company)
    # Stands in for a demo company until demo employee links land (PR #585):
    # the request path only asks whether the link's company is a demo.
    allow_any_instance_of(Company).to receive(:demo?).and_return(true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:demo_open?).and_return(true)
    allow(EmployeeAppSwitch::Enforcement).to receive(:verified?).and_return(false)
  end

  def context!
    get "/api/v1/employee/context", headers: bearer("user_jordan").merge("X-Employee-Link-Id" => link.id.to_s)
  end

  it "answers not found unless this process is guarded, and serves normally once it is" do
    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(false)
    context!
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank

    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
    context!
    expect(response).to have_http_status(:ok), response.body
  end

  it "doesn't need the waiver check once the database enforces RLS" do
    allow(EmployeeAppSwitch::Enforcement).to receive(:verified?).and_return(true)
    expect(EmployeeAppSwitch::Enforcement).not_to receive(:current_process_guarded?)
    context!
    expect(response).to have_http_status(:ok), response.body
  end
end
