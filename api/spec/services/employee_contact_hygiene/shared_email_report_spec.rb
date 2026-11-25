# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeContactHygiene::SharedEmailReport do
  let(:organization) { create(:organization) }
  let(:live) { create(:company, organization: organization) }
  let(:demo) { create_demo_company(organization: organization) }
  let(:admin) { create(:user, company: live, organization: organization, role: "admin", email: "staff-report@example.test") }

  before do
    CompanyAssignment.create!(user: admin, company: demo)
    EmployeePlaceholderEmail.create!(organization: organization, email: "marked.sample@sample-client.test", marked_by: admin)
    [ live, demo ].each do |company|
      %w[marked.sample@sample-client.test marked.sample@sample-client.test unmarked.sample@sample-client.test unmarked.sample@sample-client.test]
        .each { |email| create(:employee, company: company, email: email) }
    end
  end

  def rows_for(company)
    report = described_class.new(actor: admin, organization_id: organization.id, company_id: company.id).call
    report.fetch(:companies).flat_map { |entry| entry[:emails] }.index_by { |row| row[:email] }
  end

  it "reports a demo's marked address exactly like an unmarked one" do
    rows = rows_for(demo)
    marked = rows.fetch("marked.sample@sample-client.test").except(:email)
    unmarked = rows.fetch("unmarked.sample@sample-client.test").except(:email)
    expect(marked).to eq(unmarked)
    expect(marked).to include(marked_placeholder: false, unmarkable: false, clearable: false)
  end

  it "still flags the marked address for a live company" do
    expect(rows_for(live).fetch("marked.sample@sample-client.test")).to include(marked_placeholder: true, clearable: true)
  end
end
