# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Company RLS", :rls do
  self.use_transactional_tests = false

  let(:pool) { ActiveRecord::Base.connection_pool }

  it "classifies every primary table exactly once and stages every registered policy" do
    groups = [
      RlsTables::RLS_PROTECTED_TABLES,
      RlsTables::RLS_PARENT_PROTECTED_TABLES.keys,
      RlsTables::RLS_EXEMPT_TABLES,
      RlsTables::RLS_GLOBAL_TABLES
    ]
    pool.with_connection do |connection|
      tables = connection.tables - RlsTables::INFRASTRUCTURE_TABLES
      expect(tables.size).to be >= 194
      expect(groups.flatten).to match_array(tables)
      status = RlsDatabase.table_status(connection)
      expect(status.pluck("table")).to match_array(RlsTables::PROTECTED_TABLES.to_a)
      expect(status).to all(include("policy" => true, "enabled" => false, "forced" => false))
    end
  end

  it "rejects a query on an empty protected table" do
    TenantScope.as_system(reason: "Check fixture precondition") { expect(Department.count).to eq(0) }
    expect { Department.limit(1).load }.to raise_error(TenantScope::MissingContextError, /departments/)
  end

  it "rejects a missing key even when the table has a row" do
    pool.with_connection do |connection|
      connection.transaction do
        TenantScope.as_system(reason: "Create a protected fixture") { create(:department) }
        expect { Department.find_by(id: -1) }.to raise_error(TenantScope::MissingContextError, /departments/)
        raise ActiveRecord::Rollback
      end
    end
  end

  it "rejects a payroll service query without context" do
    expect { ContractorEinEncryption.plaintext_ids }
      .to raise_error(TenantScope::MissingContextError, /employees/)
  end

  it "rejects a cross-company service call within a company scope" do
    TenantScope.with_company(1) do
      expect { YearEnd::InputRevision.for(2, 2026) }.to raise_error(TenantScope::ConflictingContextError)
    end
  end

  it "rejects raw writes before PostgreSQL executes them" do
    pool.with_connection do |connection|
      expect do
        connection.execute("WITH deleted AS (DELETE FROM public.departments RETURNING id) SELECT id FROM deleted")
      end.to raise_error(TenantScope::MissingContextError, /departments/)
    end
  end

  it "logs a structured warning with table names and never includes values or SQL" do
    allow(RlsContextGuard).to receive(:mode).and_return("log")
    allow(Rails.logger).to receive(:warn).and_call_original
    Department.where(name: "private-fixture-name").load
    expect(Rails.logger).to have_received(:warn).with(satisfy do |line|
      event = JSON.parse(line)
      event["event"] == "rls_missing_context" && event["tables"] == [ "departments" ] &&
        event["backtrace"].is_a?(Array) && !line.include?("private-fixture-name") && !line.include?("SELECT")
    end)
  end

  it "uses system settings and logs missing context while the owner switch is on" do
    allow(RlsDatabase).to receive(:bypass_enabled?).and_return(true)
    allow(Rails.logger).to receive(:warn).and_call_original
    TenantScope.with_company(1) { expect(settings).to eq([ "", "system" ]) }
    expect { Department.limit(1).load }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).with(/"event":"rls_missing_context"/)
    expect(settings).to eq([ "", "" ])
  end

  it "permits identical nesting and refuses a different tenant or mode" do
    TenantScope.with_company(1) do
      expect(settings).to eq([ "1", "company" ])
      TenantScope.with_company("1") { expect(settings).to eq([ "1", "company" ]) }
      expect { TenantScope.with_company(2) { } }.to raise_error(TenantScope::ConflictingContextError)
      expect { TenantScope.as_system(reason: "Wrong mode") { } }.to raise_error(TenantScope::ConflictingContextError)
      expect(settings).to eq([ "1", "company" ])
    end
    TenantScope.as_system(reason: "Outer system") do
      TenantScope.as_system(reason: "Nested system") { expect(settings).to eq([ "", "system" ]) }
      expect { TenantScope.with_company(1) { } }.to raise_error(TenantScope::ConflictingContextError)
    end
    expect(settings).to eq([ "", "" ])
  end

  it "restores an already leased session's prior values on exception" do
    pool.with_connection do |connection|
      connection.raw_connection.exec_params(RlsConnection::WRITE_SETTINGS, [ "42", "" ], &:clear)
      expect { TenantScope.with_company(1) { raise "boom" } }.to raise_error("boom")
      expect(settings).to eq([ "42", "" ])
    end
    expect(TenantScope.current).to be_nil
    expect(settings).to eq([ "", "" ])
  end

  it "reuses the same backend and clears settings on checkin and checkout" do
    connection = pool.checkout
    pid = connection.raw_connection.backend_pid
    connection.raw_connection.exec_params(RlsConnection::WRITE_SETTINGS, [ "10", "company" ], &:clear)
    pool.checkin(connection)
    expect(connection.raw_connection.exec(RlsConnection::READ_SETTINGS, &:values).first).to eq([ "", "" ])

    # Simulate a stale session setting independently of the checkin callback.
    connection.raw_connection.exec_params(RlsConnection::WRITE_SETTINGS, [ "", "system" ], &:clear)
    reused = pool.checkout
    expect(reused.raw_connection.backend_pid).to eq(pid)
    expect(reused.raw_connection.exec(RlsConnection::READ_SETTINGS, &:values).first).to eq([ "", "" ])
  ensure
    pool.checkin(reused) if reused&.in_use?
    pool.checkin(connection) if connection&.in_use?
  end

  def settings
    pool.with_connection do |connection|
      connection.raw_connection.exec(RlsConnection::READ_SETTINGS, &:values).first
    end
  end

  # Step 3 SQL rehearsal. This explicit transaction rolls back the role,
  # fixtures, grants and per-table enforcement before returning the connection.
  context "with Step 3 enforcement applied inside a test transaction only" do
    it "filters wrong-company rows and rejects mismatched writes under payroll_app" do
      pool.with_connection do |connection|
        connection.transaction do
          TenantScope.as_system(reason: "Create Step 3 fixtures") do
            @department = create(:department)
            @other_company = create(:company)
            setup_step_three(connection)
          end

          expect(RlsDatabase.verify_runtime!(connection)).to be(true)
          expect { connection.select_value("SELECT public.app_current_company_id()") }.to raise_error(
            ActiveRecord::StatementInvalid, /RLS context missing/
          )
          # The SQL exception aborts the transaction. Roll back before using
          # the connection again.
          raise ActiveRecord::Rollback
        end

        connection.transaction do
          TenantScope.as_system(reason: "Create Step 3 fixtures") do
            @department = create(:department)
            @other_company = create(:company)
            setup_step_three(connection)
          end
          TenantScope.with_company(@department.company_id) { expect(Department.find(@department.id)).to eq(@department) }
          TenantScope.with_company(@other_company.id) do
            expect(Department.find_by(id: @department.id)).to be_nil
            expect(connection.select_value("SELECT id FROM departments WHERE id = #{@department.id}")).to be_nil
            expect do
              connection.transaction(requires_new: true) do
                connection.execute("INSERT INTO departments (company_id, name, created_at, updated_at) VALUES (#{@department.company_id}, 'wrong company', now(), now())")
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          TenantScope.as_system(reason: "Verify system scope") { expect(Department.find(@department.id)).to eq(@department) }
          raise ActiveRecord::Rollback
        end
      end
    end

    def setup_step_three(connection)
      connection.execute("CREATE ROLE payroll_app NOSUPERUSER NOBYPASSRLS")
      connection.execute("GRANT USAGE ON SCHEMA public, rls_admin TO payroll_app")
      connection.execute("GRANT SELECT, INSERT ON departments TO payroll_app")
      connection.execute("GRANT USAGE ON SEQUENCE departments_id_seq TO payroll_app")
      connection.execute("GRANT SELECT ON rls_admin.rls_kill_switch TO payroll_app")
      connection.execute("ALTER TABLE departments ENABLE ROW LEVEL SECURITY")
      connection.execute("ALTER TABLE departments FORCE ROW LEVEL SECURITY")
      connection.execute("SET LOCAL ROLE payroll_app")
    end
  end
end
