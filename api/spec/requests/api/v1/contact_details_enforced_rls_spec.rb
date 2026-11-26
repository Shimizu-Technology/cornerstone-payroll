# frozen_string_literal: true

require "rails_helper"

# The contact endpoints under RLS phase 3: requests run as a non-bypass
# runtime role with every registered policy enabled and forced, the guard
# in raise mode, and the login link decision function owned by a
# non-superuser role that bypasses RLS, as in production. Everything is
# rolled back inside a single explicit transaction on one checked-out
# connection.
#
# Uses per-process unique role names rather than cluster-global `payroll_app`
# and `payroll_owner_sim` so parallel CI shards sharing one PostgreSQL cluster
# never deadlock on `pg_authid`, and local runs never collide with a persistent
# `payroll_app` role.
RSpec.describe "Contact details under enforced RLS", type: :request do
  self.use_transactional_tests = false

  let(:headers) { { "X-Company-Id" => @company.id.to_s } }

  around do |example|
    # Flush any idle connections left by prior multi-threaded specs before
    # acquiring ACCESS EXCLUSIVE locks for ALTER TABLE ... ROW LEVEL SECURITY.
    ActiveRecord::Base.connection_pool.flush(-1)

    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.transaction do
        seed_fixtures!
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end

  def seed_fixtures!
    @organization = create(:organization)
    @company = create(:company, organization: @organization)
    @other_company = create(:company, organization: @organization)

    @emma_login = create(:user, company: @company, organization: @organization, role: "client",
      name: "Emma Pleadwell", email: "emma.pleadwell@example.com").tap do |user|
      CompanyAssignment.create!(user: user, company: @company)
    end
    @staff = create(:user, company: @company, organization: @organization, role: "admin",
      name: "Dafne Shimizu", email: "dafne.staff@example.com")
    @emma = create(:employee, company: @company, first_name: "Emma", last_name: "Pleadwell", email: nil)
    @dafne = create(:employee, company: @company, first_name: "Dafne", last_name: "Shimizu", email: nil)
    # A login whose only link is to an employee at another client.
    @linked_elsewhere = create(:user, company: @company, organization: @organization, role: "client",
      name: "Emma Pleadwell", email: "emma.elsewhere@example.com").tap do |user|
      elsewhere = create(:employee, company: @other_company, first_name: "Emma", last_name: "Pleadwell")
      EmployeeAccountLink.create!(company: @other_company, employee: elsewhere, user: user, status: "active")
      CompanyAssignment.create!(user: user, company: @company)
    end
  end

  def enforce_rls_like_production!
    connection = ActiveRecord::Base.connection
    suffix = "#{Process.pid}_#{SecureRandom.hex(4)}"
    app_role = connection.quote_table_name("rls_contact_app_#{suffix}")
    owner_role = connection.quote_table_name("rls_contact_owner_#{suffix}")

    # Enforce RLS before GRANT ... ON ALL TABLES so pg_class row updates from
    # GRANT cannot deadlock with autovacuum/autoanalyze before ALTER TABLE
    # acquires AccessExclusiveLock.
    RlsTables::PROTECTED_TABLES.sort.each do |table|
      quoted = connection.quote_table_name(table)
      connection.execute("ALTER TABLE #{quoted} ENABLE ROW LEVEL SECURITY")
      connection.execute("ALTER TABLE #{quoted} FORCE ROW LEVEL SECURITY")
    end
    connection.execute("CREATE ROLE #{app_role} NOSUPERUSER NOBYPASSRLS")
    connection.execute("GRANT USAGE ON SCHEMA public, rls_admin TO #{app_role}")
    connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{app_role}")
    connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{app_role}")
    connection.execute("GRANT SELECT ON rls_admin.rls_kill_switch TO #{app_role}")
    connection.execute("GRANT EXECUTE ON FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} TO #{app_role}")
    connection.execute("CREATE ROLE #{owner_role} NOLOGIN NOSUPERUSER BYPASSRLS")
    connection.execute("GRANT SELECT ON employees, employee_account_links TO #{owner_role}")
    connection.execute("ALTER FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} OWNER TO #{owner_role}")
    connection.execute("SET LOCAL ROLE #{app_role}")
  end

  def as_owner
    ActiveRecord::Base.connection.execute("RESET ROLE")
    yield
  end

  def save_email(path, employee, email)
    patch "#{path}/#{employee.id}", headers: headers, params: { employee: { email: email }, confirm_same_person_email: true }
  end

  it "runs with the guard in raise mode" do
    expect(RlsContextGuard.mode).to eq("raise")
  end

  it "saves Emma's own email and its audit when she confirms it is hers" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(@emma_login)
    enforce_rls_like_production!

    save_email("/api/v1/client/employees", @emma, @emma_login.email)
    expect(response).to have_http_status(:ok), response.body

    as_owner do
      expect(@emma.reload.email).to eq(@emma_login.email)
      expect(AuditLog.where(action: "employees#confirm_same_person_email", record_id: @emma.id).sole.metadata)
        .to include("email" => @emma_login.email, "confirmation_basis" => "self_confirmed")
    end
  end

  it "refuses the same request when Emma's login is linked only to an employee at another client" do
    elsewhere = create(:employee, company: @other_company, first_name: "Emma", last_name: "Pleadwell")
    EmployeeAccountLink.create!(company: @other_company, employee: elsewhere, user: @emma_login, status: "active")
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(@emma_login)
    enforce_rls_like_production!

    save_email("/api/v1/client/employees", @emma, @emma_login.email)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.dig("details", "email")).to eq([ EmployeeContactValidator::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])

    as_owner do
      expect(@emma.reload.email).to be_nil
      expect(AuditLog.where(action: "employees#confirm_same_person_email", record_id: @emma.id)).to be_empty
      expect(AuditLog.where(action: "employees#login_email_rejected").sole.metadata).to include("rejection_reason" => "linked_to_other_employee")
    end
  end

  it "lets Emma confirm her own email in one step, and refuses a login linked at another client, on the client endpoint" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(@emma_login)
    enforce_rls_like_production!
    TenantScope.with_company(@company.id) do
      expect(EmployeeAccountLink.where(company_id: @other_company.id).exists?).to be(false)
    end

    save_email("/api/v1/client/employees", @emma, @emma_login.email)
    expect(response).to have_http_status(:ok), response.body

    # Signed in as the other login, which is linked to an employee elsewhere.
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(@linked_elsewhere)
    save_email("/api/v1/client/employees", @emma, @linked_elsewhere.email)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.dig("details", "email")).to eq([ EmployeeContactValidator::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])

    as_owner do
      expect(@emma.reload.email).to eq(@emma_login.email)
      expect(AuditLog.where(action: "employees#confirm_same_person_email", record_id: @emma.id).count).to eq(1)
    end
  end

  it "lets staff confirm their own email in one step, and refuses a login linked at another client, on the admin endpoint" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(@staff)
    enforce_rls_like_production!

    save_email("/api/v1/admin/employees", @dafne, @staff.email)
    expect(response).to have_http_status(:ok), response.body

    save_email("/api/v1/admin/employees", @emma, @linked_elsewhere.email)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.dig("details", "email").first).to match(/already linked to another employee/i)

    as_owner do
      expect(@dafne.reload.email).to eq(@staff.email)
      expect(@emma.reload.email).to be_nil
    end
  end
end
