# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:user) { create(:user, company: company, organization: organization, role: "admin") }

  before do
    allow_any_instance_of(described_class).to receive(:auth_disabled?).and_return(false)
  end

  def issue_ticket
    CableTicketService.issue!(user: user, company_id: company.id)
  end

  it "connects an active user in an active organization" do
    connect params: { ticket: issue_ticket }

    expect(connection.current_user).to eq(user)
    expect(connection.current_company).to eq(company)
  end

  it "rejects an inactive user even when the ticket was issued before deactivation" do
    ticket = issue_ticket
    user.update_columns(active: false)

    expect { connect params: { ticket: ticket } }.to have_rejected_connection
  end

  it "rejects a regular user in an inactive organization" do
    ticket = issue_ticket
    organization.update_columns(status: "inactive")

    expect { connect params: { ticket: ticket } }.to have_rejected_connection
  end

  it "allows an active super admin to recover an inactive organization" do
    user.update!(role: "super_admin")
    ticket = issue_ticket
    organization.update_columns(status: "inactive")

    connect params: { ticket: ticket }

    expect(connection.current_user).to eq(user)
    expect(connection.current_company).to eq(company)
  end
end
