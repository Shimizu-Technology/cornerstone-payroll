# frozen_string_literal: true

require "rails_helper"

# Enforced-role boundary rehearsal for Track B demo-shape migration:
# 1. Proves that the restricted `payroll_app` runtime role cannot invoke the
#    owner-only SECURITY DEFINER conversion/revert functions, has no privileges
#    on `demo_shape_conversions`, and cannot convert/revert via direct SQL even
#    after setting the custom GUC.
# 2. Exercises a REAL non-owner PostgreSQL SESSION (separate PG.connect as a
#    test-only LOGIN NOSUPERUSER NOBYPASSRLS role with a test-only EXECUTE
#    grant) to prove the `session_user` ownership check inside both SECURITY
#    DEFINER functions rejects non-owner sessions even if EXECUTE were granted.
RSpec.describe "Demo shape migration enforced runtime role boundary", :rls do
  include EnforcedRlsHelpers

  let(:connection) { ActiveRecord::Base.connection }
  let!(:organization) { create(:organization) }
  let!(:live) { create(:company, organization: organization, name: "Live Client") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin") }
  let!(:legacy_demo) do
    create_demo_company(
      organization: organization,
      name: "Harbor Finch Kitchen",
      fixture_key: "enforced-rls-legacy"
    )
  end
  let!(:flag_demo) do
    create_live_demo_company(
      organization: organization,
      name: "Harbor Finch Flag",
      fixture_key: "enforced-rls-flag"
    )
  end

  before do
    allow(RlsContextGuard).to receive(:mode).and_return("raise")
    enforce_as_runtime_role!
  end

  it "revokes EXECUTE on conversion and revert functions and blocks demo_shape_conversions writes from payroll_app" do
    expect(connection.select_value("SELECT current_user")).to eq("payroll_app")
    expect(
      connection.select_value("SELECT has_function_privilege('payroll_app', 'convert_demo_company_to_flag(bigint, bigint, timestamp with time zone)', 'EXECUTE')")
    ).to be(false)
    expect(
      connection.select_value("SELECT has_function_privilege('payroll_app', 'revert_demo_company_to_legacy_shape(bigint, bigint, boolean, timestamp with time zone)', 'EXECUTE')")
    ).to be(false)

    TenantScope.as_system(reason: "Attempt unauthorized demo conversion as payroll_app") do
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.select_value("SELECT convert_demo_company_to_flag(#{legacy_demo.id}, #{admin.id}, NOW())")
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /permission denied for function convert_demo_company_to_flag/i)

      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.select_value("SELECT revert_demo_company_to_legacy_shape(1, #{admin.id}, true, NOW())")
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /permission denied for function revert_demo_company_to_legacy_shape/i)

      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute("SET LOCAL app.demo_shape_migration_op = 'convert'")
          connection.execute(<<~SQL.squish)
            INSERT INTO demo_shape_conversions
              (organization_id, company_id, actor_id, before_company_shape, before_link_environments, after_company_shape, converted_at, created_at, updated_at)
            VALUES
              (#{organization.id}, #{flag_demo.id}, #{admin.id}, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, NOW(), NOW(), NOW())
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo_shape_conversions can only be written by demo shape conversion/)
    end
  end

  it "blocks payroll_app from converting or reverting a demo via raw SQL even after setting the GUC" do
    expect(connection.select_value("SELECT current_user")).to eq("payroll_app")

    TenantScope.as_system(reason: "Attempt GUC-spoofed SQL conversion as payroll_app") do
      # Without GUC
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL
            WHERE id = #{legacy_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # With spoofed convert GUC
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute("SET LOCAL app.demo_shape_migration_op = 'convert'")
          connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL
            WHERE id = #{legacy_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # With spoofed revert GUC
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute("SET LOCAL app.demo_shape_migration_op = 'revert'")
          connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = FALSE, payroll_environment = 'migration_rehearsal', test_workspace_purpose = 'demo',
                migration_rehearsal_status = 'ready'
            WHERE id = #{flag_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      expect(legacy_demo.reload).to be_legacy_demo
      expect(flag_demo.reload[:demo]).to be(true)
      expect(flag_demo.payroll_environment).to eq("live")
    end
  end
end

RSpec.describe "Demo shape migration real non-owner session_user boundary" do
  self.use_transactional_tests = false

  it "rejects a real non-owner PG session inside both SECURITY DEFINER functions even with a test-only EXECUTE grant" do
    role_name = "demo_mig_non_owner_#{SecureRandom.hex(4)}"
    password = SecureRandom.hex(16)
    conn = ActiveRecord::Base.connection
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    organization = nil
    non_owner_conn = nil

    begin
      organization = create(:organization)
      live = create(:company, organization: organization, name: "Live Client")
      admin = create(:user, company: live, organization: organization, role: "admin")
      legacy_demo = create_demo_company(organization: organization, name: "Session Test Demo", fixture_key: "session-test-demo")

      conn.execute("CREATE ROLE #{role_name} LOGIN PASSWORD #{conn.quote(password)} NOSUPERUSER NOBYPASSRLS")
      conn.execute("GRANT USAGE ON SCHEMA public TO #{role_name}")
      conn.execute("GRANT EXECUTE ON FUNCTION public.convert_demo_company_to_flag(bigint, bigint, timestamp with time zone) TO #{role_name}")
      conn.execute("GRANT EXECUTE ON FUNCTION public.revert_demo_company_to_legacy_shape(bigint, bigint, boolean, timestamp with time zone) TO #{role_name}")

      connect_opts = db_config.slice(:host, :port).compact.merge(
        dbname: ActiveRecord::Base.connection_db_config.database,
        user: role_name,
        password: password
      )
      non_owner_conn = PG.connect(connect_opts)

      expect(non_owner_conn.exec("SELECT session_user").getvalue(0, 0)).to eq(role_name)

      expect {
        non_owner_conn.exec("SELECT public.convert_demo_company_to_flag(#{legacy_demo.id}, #{admin.id}, NOW())")
      }.to raise_error(PG::InsufficientPrivilege, /demo shape conversion requires the table owner role/)

      expect {
        non_owner_conn.exec("SELECT public.revert_demo_company_to_legacy_shape(1, #{admin.id}, true, NOW())")
      }.to raise_error(PG::InsufficientPrivilege, /demo shape revert requires the table owner role/)

      expect(legacy_demo.reload).to be_legacy_demo
    ensure
      non_owner_conn&.close
      conn.execute("REVOKE ALL ON FUNCTION public.convert_demo_company_to_flag(bigint, bigint, timestamp with time zone) FROM #{role_name}") rescue nil
      conn.execute("REVOKE ALL ON FUNCTION public.revert_demo_company_to_legacy_shape(bigint, bigint, boolean, timestamp with time zone) FROM #{role_name}") rescue nil
      conn.execute("REVOKE ALL ON SCHEMA public FROM #{role_name}") rescue nil
      conn.execute("DROP ROLE IF EXISTS #{role_name}") rescue nil
      if organization
        conn.transaction do
          conn.execute("SET LOCAL session_replication_role = replica")
          cids = conn.select_values("SELECT id FROM companies WHERE organization_id = #{organization.id}")
          if cids.any?
            conn.execute("DELETE FROM demo_shape_conversions WHERE company_id IN (#{cids.join(',')})")
            conn.execute("DELETE FROM audit_logs WHERE company_id IN (#{cids.join(',')})")
          end
          conn.execute("DELETE FROM invoice_billing_profiles WHERE organization_id = #{organization.id}")
          conn.execute("DELETE FROM finance_books WHERE organization_id = #{organization.id}")
          conn.execute("DELETE FROM users WHERE organization_id = #{organization.id}")
          conn.execute("DELETE FROM companies WHERE organization_id = #{organization.id}")
          conn.execute("DELETE FROM organizations WHERE id = #{organization.id}")
        end
      end
    end
  end
end
