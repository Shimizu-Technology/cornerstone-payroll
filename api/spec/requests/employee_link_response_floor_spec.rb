# frozen_string_literal: true

require "rails_helper"

# The response floor waits only after the request's database work is done and
# its connection is back in the pool. Not transactional, so the test's own
# transaction doesn't pin a connection; the request writes nothing.
RSpec.describe "Employee link response floor", type: :request do
  include EmployeeLinkHelpers

  self.use_transactional_tests = false

  it "holds no database connection or tenant scope while it waits" do
    allow(EmployeeLinks::ResponseFloor).to receive(:enabled?).and_return(true)
    during_pause = []
    allow(EmployeeLinks::ResponseFloor).to receive(:pause) do
      during_pause << {
        leased: ActiveRecord::Base.connection_handler.connection_pool_list(:all).count(&:active_connection?),
        scope: TenantScope.current
      }
    end

    expect do
      post_activation({ token: "not-a-real-invite-token", date_of_birth: "1990-04-12", ssn_last4: "1234",
        email: "someone@example.net" })
    end.not_to change(AuditLog, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(during_pause).to eq([ { leased: 0, scope: nil } ])
  end
end
