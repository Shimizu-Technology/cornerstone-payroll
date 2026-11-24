# frozen_string_literal: true

require "rails_helper"

# The contact endpoints under RLS phase 3: requests run as a non-bypass
# payroll_app role with employees and employee_account_links enabled and
# forced, and the login link decision function owned by a non-superuser role
# that bypasses RLS, as in production. Everything is rolled back with the
# example's transaction.
RSpec.describe "Contact details under enforced RLS", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:other_company) { create(:company, organization: organization) }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  let!(:emma_login) do
    create(:user, company: company, organization: organization, role: "client", name: "Emma Pleadwell", email: "emma.pleadwell@example.com").tap do |user|
      CompanyAssignment.create!(user: user, company: company)
    end
  end
  let!(:staff) { create(:user, company: company, organization: organization, role: "admin", name: "Dafne Shimizu", email: "dafne.staff@example.com") }
  let!(:emma) { create(:employee, company: company, first_name: "Emma", last_name: "Pleadwell", email: nil) }
  let!(:dafne) { create(:employee, company: company, first_name: "Dafne", last_name: "Shimizu", email: nil) }
  # A login whose only link is to an employee at another client.
  let!(:linked_elsewhere) do
    create(:user, company: company, organization: organization, role: "client", name: "Emma Pleadwell", email: "emma.elsewhere@example.com").tap do |user|
      elsewhere = create(:employee, company: other_company, first_name: "Emma", last_name: "Pleadwell")
      EmployeeAccountLink.create!(company: other_company, employee: elsewhere, user: user, status: "active")
      CompanyAssignment.create!(user: user, company: company)
    end
  end

  def enforce_rls_like_production!
    connection = ActiveRecord::Base.connection
    connection.execute("CREATE ROLE payroll_app NOSUPERUSER NOBYPASSRLS")
    connection.execute("GRANT USAGE ON SCHEMA public, rls_admin TO payroll_app")
    connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO payroll_app")
    connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO payroll_app")
    connection.execute("GRANT SELECT ON rls_admin.rls_kill_switch TO payroll_app")
    connection.execute("GRANT EXECUTE ON FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} TO payroll_app")
    connection.execute("CREATE ROLE payroll_owner_sim NOLOGIN NOSUPERUSER BYPASSRLS")
    connection.execute("GRANT SELECT ON employees, employee_account_links TO payroll_owner_sim")
    connection.execute("ALTER FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} OWNER TO payroll_owner_sim")
    %w[employees employee_account_links].each do |table|
      connection.execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
      connection.execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")
    end
    connection.execute("SET LOCAL ROLE payroll_app")
  end

  def as_owner
    ActiveRecord::Base.connection.execute("RESET ROLE")
    yield
  end

  def save_email(path, employee, email)
    patch "#{path}/#{employee.id}", headers: headers, params: { employee: { email: email }, confirm_same_person_email: true }
  end

  it "lets Emma confirm her own email in one step, and refuses a login linked at another client, on the client endpoint" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(emma_login)
    enforce_rls_like_production!
    TenantScope.with_company(company.id) do
      expect(EmployeeAccountLink.where(company_id: other_company.id).exists?).to be(false)
    end

    save_email("/api/v1/client/employees", emma, emma_login.email)
    expect(response).to have_http_status(:ok), response.body

    # Signed in as the other login, which is linked to an employee elsewhere.
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(linked_elsewhere)
    save_email("/api/v1/client/employees", emma, linked_elsewhere.email)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.dig("details", "email")).to eq([ EmployeeContactValidator::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])

    as_owner do
      expect(emma.reload.email).to eq(emma_login.email)
      expect(AuditLog.where(action: "employees#confirm_same_person_email", record_id: emma.id).count).to eq(1)
    end
  end

  it "lets staff confirm their own email in one step, and refuses a login linked at another client, on the admin endpoint" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(staff)
    enforce_rls_like_production!

    save_email("/api/v1/admin/employees", dafne, staff.email)
    expect(response).to have_http_status(:ok), response.body

    save_email("/api/v1/admin/employees", emma, linked_elsewhere.email)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.dig("details", "email").first).to match(/already linked to another employee/i)

    as_owner do
      expect(dafne.reload.email).to eq(staff.email)
      expect(emma.reload.email).to be_nil
    end
  end
end
