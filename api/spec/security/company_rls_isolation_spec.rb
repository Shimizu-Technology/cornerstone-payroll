# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Company RLS", :rls do
  self.use_transactional_tests = false

  before(:each, :raises_without_context) do
    allow(RlsContextGuard).to receive(:mode).and_return("raise")
  end

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

  it "accounts for every nullable company ID and requires it on every promoted child" do
    pool.with_connection do |connection|
      nullable = connection.select_values(<<~SQL)
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = current_schema() AND column_name = 'company_id' AND is_nullable = 'YES'
      SQL
      expect(nullable).to match_array(
        RlsTables::RLS_SHARED_READ_TABLES +
          %w[audit_logs finance_books invoice_chat_sessions invoice_recipients invoices work_hour_client_links]
      )
      expect(RlsEnforcement.nullable_child_companies(connection)).to be_empty
    end
  end

  it "rejects a query on an empty protected table", :raises_without_context do
    TenantScope.as_system(reason: "Check fixture precondition") { expect(Department.count).to eq(0) }
    expect { Department.limit(1).load }.to raise_error(TenantScope::MissingContextError, /departments/)
  end

  it "rejects a missing key even when the table has a row", :raises_without_context do
    pool.with_connection do |connection|
      connection.transaction do
        TenantScope.as_system(reason: "Create a protected fixture") { create(:department) }
        expect { Department.find_by(id: -1) }.to raise_error(TenantScope::MissingContextError, /departments/)
        raise ActiveRecord::Rollback
      end
    end
  end

  it "rejects a payroll service query without context", :raises_without_context do
    expect { ContractorEinEncryption.plaintext_ids }
      .to raise_error(TenantScope::MissingContextError, /employees/)
  end

  it "rejects a cross-company service call within a company scope" do
    TenantScope.with_company(1) do
      expect { YearEnd::InputRevision.for(2, 2026) }.to raise_error(TenantScope::ConflictingContextError)
    end
  end

  it "rejects raw writes before PostgreSQL executes them", :raises_without_context do
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
    allow(RlsConfiguration).to receive(:runtime_url).and_return("postgres://localhost/test")
    stub_const("RlsDatabase::SWITCH_CACHE", Concurrent::AtomicReference.new)
    allow(Rails.logger).to receive(:warn).and_call_original
    pool.with_connection do |connection|
      connection.transaction do
        connection.execute("UPDATE rls_admin.rls_kill_switch SET bypass_enabled = true WHERE singleton")
        TenantScope.with_company(1) { expect(settings).to eq([ "", "system" ]) }
        expect { Department.limit(1).load }.not_to raise_error
        expect(Rails.logger).to have_received(:warn).with(/"event":"rls_missing_context"/)
        expect(settings).to eq([ "", "" ])
        raise ActiveRecord::Rollback
      end
      RlsDatabase::SWITCH_CACHE.set(nil)
      TenantScope.with_company(1) { expect(settings).to eq([ "1", "company" ]) }
    end
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

  it "refuses a nested raw lease and keeps the outer company lease intact" do
    # A nested lease used to clear the outer lease's marker on exit, so later
    # queries in the company scope looked unscoped.
    TenantScope.with_company(1) do
      pool.with_connection do |connection|
        expect { connection.with_tenant_settings(nil, "system") { raise "never runs" } }
          .to raise_error(RlsConnection::NestedTenantSettingsError, /nest TenantScope instead/)
        expect(settings).to eq([ "1", "company" ])
        expect(connection.tenant_settings_active?).to be(true)
        expect { Department.where(company_id: 1).exists? }.not_to raise_error
      end
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

  it "restores the active company after an inner transaction fails" do
    TenantScope.with_company(1) do
      pool.with_connection do |connection|
        pid = connection.raw_connection.backend_pid
        expect do
          connection.transaction { connection.execute("SELECT 1 / 0") }
        end.to raise_error(ActiveRecord::StatementInvalid, /division by zero/)
        expect(connection.raw_connection.backend_pid).to eq(pid)
        expect(settings).to eq([ "1", "company" ])
      end
    end
    expect(settings).to eq([ "", "" ])
  end

  it "defers removing company settings when the scope unwinds before transaction rollback" do
    pool.with_connection do |connection|
      pid = connection.raw_connection.backend_pid
      expect do
        connection.transaction do
          connection.execute("SELECT 1")
          TenantScope.with_company(1) { connection.execute("SELECT 1 / 0") }
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /division by zero/)
      expect(connection.raw_connection.backend_pid).to eq(pid)
      expect(settings).to eq([ "", "" ])
      expect(connection.select_value("SELECT 42")).to eq(42)
    end
  end

  it "preserves earlier outer writes and the prior context on a failed savepoint" do
    pool.with_connection do |connection|
      connection.transaction do
        company = create(:company)
        pid = connection.raw_connection.backend_pid
        expect do
          connection.transaction(requires_new: true) do
            connection.execute("SELECT 1")
            TenantScope.with_company(company.id) { connection.execute("SELECT 1 / 0") }
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /division by zero/)
        expect(connection.raw_connection.backend_pid).to eq(pid)
        expect(settings).to eq([ "", "" ])
        expect(Company.exists?(company.id)).to be(true)
        TenantScope.with_company(company.id) { expect(settings).to eq([ company.id.to_s, "company" ]) }
        raise ActiveRecord::Rollback
      end
    end
  end

  it "isolates simultaneous company scopes on different threads" do
    ready = Queue.new
    proceed = Queue.new
    threads = [ 1, 2 ].map do |id|
      Thread.new do
        TenantScope.with_company(id) do
          ready.push(true)
          proceed.pop
          [ TenantScope.current.company_id, settings, pool.active_connection?.raw_connection.backend_pid ]
        end
      end
    end
    results = Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { proceed.push(true) }
      threads.map(&:value)
    end
    expect(results.map { |id, gucs, _pid| [ id, gucs ] }).to eq([ [ "1", [ "1", "company" ] ], [ "2", [ "2", "company" ] ] ])
    expect(results.map(&:last).uniq.size).to eq(2)
    expect(settings).to eq([ "", "" ])
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
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

    it "isolates frozen employee documents and rejects cross-company source references" do
      pool.with_connection do |connection|
        connection.transaction do
          documents = TenantScope.as_system(reason: "Create employee document fixtures") do
            employees = create_list(:employee, 2)
            fixture = { tax_year: 2026, revision: 1, sha256: "a" * 64, storage_key: "fixture", posted_at: Time.current }
            local, foreign = employees.map do |employee|
              EmployeeDocument.create!(**fixture, employee: employee, company_id: employee.company_id)
            end
            expect do
              connection.transaction(requires_new: true) do
                EmployeeDocument.create!(**fixture, revision: 2, employee_id: foreign.employee_id, company_id: local.company_id)
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            setup_step_three(connection, tables: %w[employee_documents])
            [ local, foreign ]
          end

          local, foreign = documents
          TenantScope.with_company(local.company_id) do
            expect(EmployeeDocument.pluck(:id)).to eq([ local.id ])
            expect(EmployeeDocument.where(id: foreign.id).update_all(status: "withdrawn")).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                EmployeeDocument.create!(foreign.attributes.except("id").merge("revision" => 2))
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    it "isolates employee document notices and rejects a notice for another company's document" do
      pool.with_connection do |connection|
        connection.transaction do
          notices = TenantScope.as_system(reason: "Create employee document notice fixtures") do
            fixture = { tax_year: 2026, revision: 1, sha256: "b" * 64, storage_key: "fixture", posted_at: Time.current }
            rows = create_list(:employee, 2).map do |employee|
              document = EmployeeDocument.create!(**fixture, employee: employee, company_id: employee.company_id)
              EmployeeDocumentNotice.create!(company_id: employee.company_id, employee: employee, employee_document: document,
                kind: "w2gu_available")
            end
            local, foreign = rows
            expect do
              connection.transaction(requires_new: true) do
                EmployeeDocumentNotice.create!(company_id: local.company_id, employee_id: local.employee_id,
                  employee_document_id: foreign.employee_document_id, kind: "w2gu_available")
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            setup_step_three(connection, tables: %w[employee_document_notices])
            rows
          end

          local, foreign = notices
          TenantScope.with_company(local.company_id) do
            expect(EmployeeDocumentNotice.pluck(:id)).to eq([ local.id ])
            expect(EmployeeDocumentNotice.where(id: foreign.id).update_all(delivery_status: "bounced")).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                EmployeeDocumentNotice.insert_all!([ foreign.attributes.except("id", "created_at", "updated_at").merge("kind" => "w2gu_available") ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    it "lets tenants read shared rules and only maintain their own rules" do
      pool.with_connection do |connection|
        connection.transaction do
          company = create(:company)
          other_company = create(:company)
          shared, owned, foreign = TenantScope.as_system(reason: "Create tax-rule policy fixtures") do
            rules = [ nil, company.id, other_company.id ].map { |id| PayComponentTaxRule.insert_all!([ rule_attributes.merge(company_id: id) ], returning: %w[id]).rows.first.first }
            setup_step_three(connection, tables: %w[pay_component_tax_rules])
            rules
          end

          TenantScope.with_company(company.id) do
            expect(PayComponentTaxRule.for_company_or_global(company.id).pluck(:id)).to match_array([ shared, owned ])
            expect(PayComponentTaxRule.pluck(:id)).to match_array([ shared, owned ])
            expect(PayComponentTaxRule.where(id: [ shared, foreign ]).update_all(display_name: "Forbidden")).to eq(0)
            expect(PayComponentTaxRule.where(id: [ shared, foreign ]).delete_all).to eq(0)
            expect(PayComponentTaxRule.where(id: owned).update_all(display_name: "Owned override")).to eq(1)
            expect do
              connection.transaction(requires_new: true) do
                PayComponentTaxRule.insert_all!([ rule_attributes.merge(component_key: "forbidden_global") ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          TenantScope.as_system(reason: "Maintain shared rules") do
            expect(PayComponentTaxRule.where(id: shared).update_all(display_name: "System edit")).to eq(1)
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    it "enforces parent ownership, promoted child ownership and organization-only audit rows" do
      pool.with_connection do |connection|
        connection.transaction do
          company = create(:company)
          other_company = create(:company)
          receipts, totals, audit = TenantScope.as_system(reason: "Create parent and promoted-child policy fixtures") do
            receipt_ids = [ company, other_company ].map do |owner|
              doc = create(:client_document, company: owner)
              PortalDocumentReadReceipt.create!(client_document: doc, user: create(:user, company: owner), opened_at: Time.current).id
            end
            total_ids = [ company, other_company ].map do |owner|
              DepartmentYtdTotal.create!(department: create(:department, company: owner), year: 2026).id
            end
            audit_id = AuditLog.record!(actor: AuditActor.system_job("RLS rehearsal"), company_id: nil,
              organization_id: company.organization_id, action: "rls#probe", record_type: "probe").id
            setup_step_three(connection, tables: %w[client_documents portal_document_read_receipts department_ytd_totals audit_logs])
            [ receipt_ids, total_ids, audit_id ]
          end
          TenantScope.with_company(company.id) do
            expect(PortalDocumentReadReceipt.where(id: receipts).pluck(:id)).to eq(receipts.first(1))
            expect(DepartmentYtdTotal.where(id: totals).pluck(:id)).to eq(totals.first(1))
            expect(AuditLog.exists?(audit)).to be(false)
          end
          TenantScope.as_system(reason: "Read organization audit") { expect(AuditLog.exists?(audit)).to be(true) }
          raise ActiveRecord::Rollback
        end
      end
    end

    # Mirrors production: the function's owner is a non-superuser role that
    # bypasses RLS (like the migration owner), not the test superuser.
    def own_decision_function_like_production(connection, bypass: true)
      connection.execute("CREATE ROLE payroll_owner_sim NOLOGIN NOSUPERUSER #{bypass ? 'BYPASSRLS' : 'NOBYPASSRLS'}")
      connection.execute("GRANT SELECT ON employees, employee_account_links TO payroll_owner_sim")
      connection.execute("ALTER FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} OWNER TO payroll_owner_sim")
    end

    def decide(user, company, employees)
      EmployeeAccountLink.contact_email_link_decision(user_id: user.id, company_id: company.id, allowed_employee_ids: employees.map(&:id))
    end

    def create_link_decision_fixtures(connection, owner_bypass: true)
      company = create(:company)
      other_company = create(:company, organization: company.organization)
      TenantScope.as_system(reason: "Create login link decision RLS fixtures") do
        login = ->(name) { create(:user, company: company, organization: company.organization, role: "client", name: name) }
        here, here_other = create(:employee, company: company), create(:employee, company: company)
        there, there_invited = create(:employee, company: other_company), create(:employee, company: other_company)
        users = %w[elsewhere own none revoked former both].index_with { |name| login.call(name.titleize) }
        EmployeeAccountLink.create!(company: other_company, employee: there, user: users["elsewhere"], status: "active")
        EmployeeAccountLink.create!(company: company, employee: here, user: users["own"], status: "active")
        EmployeeAccountLink.create!(company: other_company, employee: there, user: users["revoked"], status: "revoked", revoked_at: 1.day.ago)
        EmployeeAccountLink.create!(company: other_company, employee: there, user: users["former"], status: "former",
          former_at: 2.months.ago, former_access_until: 1.month.ago)
        EmployeeAccountLink.create!(company: company, employee: here_other, user: users["both"], status: "active")
        EmployeeAccountLink.create!(company: other_company, employee: there_invited, user: users["both"], status: "invited")
        own_decision_function_like_production(connection, bypass: owner_bypass)
        # payroll_app reads every table in production (rls_runtime_role.sql);
        # contact validation also checks whether the actor is a demo login.
        setup_step_three(connection, tables: %w[employee_account_links employees], read_tables: %w[users companies company_assignments])
        { company: company, other_company: other_company, here: here, here_other: here_other, there: there, users: users }
      end
    end

    it "decides cross-company login links through the decision function inside a company scope without exposing rows" do
      pool.with_connection do |connection|
        connection.transaction do
          f = create_link_decision_fixtures(connection)
          users = f[:users]

          TenantScope.with_company(f[:company].id) do
            # payroll_app still can't read company B's links directly.
            expect(EmployeeAccountLink.where(company_id: f[:other_company].id).exists?).to be(false)
            expect(connection.select_value("SELECT count(*) FROM employee_account_links WHERE company_id = #{f[:other_company].id}")).to eq(0)

            expect(decide(users["elsewhere"], f[:company], [ f[:here] ])).to eq(:conflict)
            expect(decide(users["own"], f[:company], [ f[:here] ])).to eq(:allowed)
            expect(decide(users["own"], f[:company], [ f[:here_other] ])).to eq(:conflict)
            expect(decide(users["none"], f[:company], [ f[:here] ])).to eq(:none)
            # Revoked links never count; a former link still belongs to that employee.
            expect(decide(users["revoked"], f[:company], [ f[:here] ])).to eq(:none)
            expect(decide(users["former"], f[:company], [ f[:here] ])).to eq(:conflict)
            # An allowed link here doesn't hide an open invite elsewhere.
            expect(decide(users["both"], f[:company], [ f[:here_other] ])).to eq(:conflict)
            # It can't confirm another company's employee from this scope.
            expect(decide(users["elsewhere"], f[:other_company], [ f[:there] ])).to eq(:conflict)

            # Even the login's own "this is me" confirmation is refused.
            result = EmployeeContactValidator.call(
              employee: f[:here], company: f[:company], email: users["elsewhere"].email,
              confirm_same_person_email: true, actor: users["elsewhere"], flagged_emails: Set.new
            )
            expect(result).to have_attributes(login_email_rejected: true, login_email_rejection_reason: "linked_to_other_employee")
            expect(result).not_to be_valid
            expect(settings).to eq([ f[:company].id.to_s, "company" ])
            expect(connection.tenant_settings_active?).to be(true)
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    it "fails closed, never 'none', when the function's owner no longer bypasses RLS" do
      pool.with_connection do |connection|
        connection.transaction do
          f = create_link_decision_fixtures(connection, owner_bypass: false)
          users = f[:users]

          TenantScope.with_company(f[:company].id) do
            # row_security = off makes PostgreSQL refuse instead of hiding rows.
            expect do
              connection.transaction(requires_new: true) do
                connection.select_value("SELECT payroll_employee_login_link_decision(#{users['elsewhere'].id}, #{f[:company].id}, '{#{f[:here].id}}')")
              end
            end.to raise_error(ActiveRecord::StatementInvalid, /row-level security/)

            expect(decide(users["elsewhere"], f[:company], [ f[:here] ])).to eq(:unknown)
            expect(decide(users["none"], f[:company], [ f[:here] ])).to eq(:unknown)
            result = EmployeeContactValidator.call(
              employee: f[:here], company: f[:company], email: users["elsewhere"].email,
              confirm_same_person_email: true, actor: users["elsewhere"], flagged_emails: Set.new
            )
            expect(result).to have_attributes(login_email_rejected: true, login_email_rejection_reason: "link_check_unavailable")
            # The caller's transaction is still usable.
            expect(Employee.where(id: f[:here].id).exists?).to be(true)
          end
          connection.execute("RESET ROLE")
          expect(RlsDatabase.login_link_decision_ready?(connection)).to be(false)
          raise ActiveRecord::Rollback
        end
      end
    end

    it "returns only the three decision strings, and only payroll_app may execute it" do
      pool.with_connection do |connection|
        connection.transaction do
          f = create_link_decision_fixtures(connection)
          TenantScope.with_company(f[:company].id) do
            answers = f[:users].values.flat_map do |user|
              [ [ user.id, f[:company].id, "{#{f[:here].id}}" ], [ user.id, nil, nil ], [ user.id, f[:company].id, "{}" ] ].map do |args|
                connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT payroll_employee_login_link_decision(?::bigint, ?::bigint, ?::bigint[])", *args ]))
              end
            end
            expect(answers.uniq - %w[allowed conflict none]).to be_empty
            expect(connection.select_value("SELECT payroll_employee_login_link_decision(NULL, NULL, NULL)")).to eq("none")
            # Without allowed employees any link conflicts, so a missing input never accepts a login.
            expect(connection.select_value("SELECT payroll_employee_login_link_decision(#{f[:users]['own'].id}, NULL, NULL)")).to eq("conflict")
            expect(connection.select_rows("SELECT * FROM payroll_employee_login_link_decision(1, 1, '{1}')").sole.size).to eq(1)
          end
          connection.execute("RESET ROLE")
          expect(connection.select_value("SELECT has_function_privilege('payroll_app', '#{RlsDatabase::LOGIN_LINK_DECISION}', 'EXECUTE')")).to be(true)
          connection.execute("CREATE ROLE payroll_probe NOLOGIN")
          expect(connection.select_value("SELECT has_function_privilege('payroll_probe', '#{RlsDatabase::LOGIN_LINK_DECISION}', 'EXECUTE')")).to be(false)
          expect(RlsDatabase.login_link_decision_status(connection)).to include(
            "installed" => true, "security_definer" => true, "stable" => true, "search_path_pinned" => true,
            "row_security_off" => true, "owner" => "payroll_owner_sim", "owner_bypasses_rls" => true,
            "execute_grantees" => %w[payroll_app payroll_owner_sim], "public_can_execute" => false,
            "grant_option_granted" => false, "runtime_can_execute" => true
          )
          expect(RlsDatabase.login_link_decision_ready?(connection)).to be(true)

          # Any extra grantee, or a grant option for the runtime role, fails readiness.
          connection.execute("GRANT EXECUTE ON FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} TO payroll_probe")
          expect(RlsDatabase.login_link_decision_ready?(connection)).to be(false)
          connection.execute("REVOKE EXECUTE ON FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} FROM payroll_probe")
          expect(RlsDatabase.login_link_decision_ready?(connection)).to be(true)
          connection.execute("GRANT EXECUTE ON FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} TO payroll_app WITH GRANT OPTION")
          expect(RlsDatabase.login_link_decision_ready?(connection)).to be(false)
          raise ActiveRecord::Rollback
        end
      end
    end

    it "fails closed while the decision function is missing" do
      pool.with_connection do |connection|
        connection.transaction do
          f = TenantScope.as_system(reason: "Create missing-function fixtures") do
            connection.execute("DROP FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION}")
            create_link_decision_fixtures_without_function(connection)
          end

          # Outside a scope the system read still sees every company.
          expect(decide(f[:users]["elsewhere"], f[:company], [ f[:here] ])).to eq(:conflict)
          TenantScope.with_company(f[:company].id) do
            expect(decide(f[:users]["elsewhere"], f[:company], [ f[:here] ])).to eq(:unknown)
            expect(decide(f[:users]["own"], f[:company], [ f[:here] ])).to eq(:unknown)
            expect(settings).to eq([ f[:company].id.to_s, "company" ])
          end
          expect(RlsDatabase.login_link_decision_ready?(connection)).to be(false)
          raise ActiveRecord::Rollback
        end
      end
    end

    def create_link_decision_fixtures_without_function(connection)
      company = create(:company)
      other_company = create(:company, organization: company.organization)
      here, there = create(:employee, company: company), create(:employee, company: other_company)
      users = %w[elsewhere own].index_with { |name| create(:user, company: company, organization: company.organization, role: "client", name: name.titleize) }
      EmployeeAccountLink.create!(company: other_company, employee: there, user: users["elsewhere"], status: "active")
      EmployeeAccountLink.create!(company: company, employee: here, user: users["own"], status: "active")
      setup_step_three(connection, tables: %w[employee_account_links employees], read_tables: %w[users], decision_function: false)
      { company: company, here: here, users: users }
    end

    it "keeps each company's Help contacts to that company" do
      pool.with_connection do |connection|
        connection.transaction do
          company = create(:company)
          other_company = create(:company)
          own, foreign = TenantScope.as_system(reason: "Create Help contact policy fixtures") do
            ids = [ company, other_company ].map do |owner|
              CompanyHelpContact.create!(company: owner, position: 1, name: "Help #{owner.id}", phone: "671-555-0100").id
            end
            setup_step_three(connection, tables: %w[company_help_contacts])
            ids
          end

          TenantScope.with_company(company.id) do
            expect(CompanyHelpContact.pluck(:id)).to eq([ own ])
            expect(CompanyHelpContact.where(id: foreign).update_all(name: "Changed")).to eq(0)
            expect(CompanyHelpContact.where(id: foreign).delete_all).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                CompanyHelpContact.insert_all!([ { company_id: other_company.id, position: 2, name: "Planted", phone: "671-555-0199",
                                                   created_at: Time.current, updated_at: Time.current } ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          TenantScope.as_system(reason: "Verify Help contacts") { expect(CompanyHelpContact.where(id: [ own, foreign ]).count).to eq(2) }
          raise ActiveRecord::Rollback
        end
      end
    end

    it "isolates emergency contacts and enforces employee ownership" do
      pool.with_connection do |connection|
        connection.transaction do
          company, other_company = create(:company), create(:company)
          attrs = { name: "Example Contact", phone: "+16715550100" }
          own, foreign = TenantScope.as_system(reason: "Create emergency contact RLS fixtures") do
            contacts = [ company, other_company ].map do |owner|
              EmployeeEmergencyContact.create!(company: owner, employee: create(:employee, company: owner), **attrs)
            end
            expect do
              connection.transaction(requires_new: true) do
                EmployeeEmergencyContact.create!(company: company, employee_id: contacts.last.employee_id, **attrs)
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            setup_step_three(connection, tables: %w[employee_emergency_contacts])
            contacts
          end

          TenantScope.with_company(company.id) do
            expect(EmployeeEmergencyContact.order(:id).pluck(:id)).to eq([ own.id ])
            expect(EmployeeEmergencyContact.where(id: foreign.id).update_all(name: "Changed")).to eq(0)
            expect(EmployeeEmergencyContact.where(id: foreign.id).delete_all).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                EmployeeEmergencyContact.insert_all!([ attrs.merge(company_id: other_company.id, employee_id: foreign.employee_id) ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    it "isolates payroll contact confirmations and rejects a mismatched employee company" do
      pool.with_connection do |connection|
        connection.transaction do
          company, other_company = create(:company), create(:company)
          own, foreign = TenantScope.as_system(reason: "Create contact confirmation policy fixtures") do
            entries = [ company, other_company ].map do |owner|
              EmployeeContactChangeToConfirm.create!(
                company: owner, employee: create(:employee, company: owner), change_kind: "address"
              )
            end
            expect do
              connection.transaction(requires_new: true) do
                EmployeeContactChangeToConfirm.create!(
                  company: company, employee_id: entries.last.employee_id, change_kind: "address"
                )
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            setup_step_three(connection, tables: %w[employee_contact_changes_to_confirm])
            entries
          end

          TenantScope.with_company(company.id) do
            expect(EmployeeContactChangeToConfirm.pluck(:id)).to eq([ own.id ])
            expect(EmployeeContactChangeToConfirm.where(id: foreign.id).update_all(confirmed_at: Time.current)).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                EmployeeContactChangeToConfirm.create!(
                  company_id: other_company.id, employee_id: foreign.employee_id, change_kind: "address"
                )
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    it "isolates delivery consents and enforces employee and link ownership" do
      pool.with_connection do |connection|
        connection.transaction do
          company, other_company = create(:company), create(:company)
          own, foreign = TenantScope.as_system(reason: "Create delivery consent RLS fixtures") do
            disclosure = DeliveryDisclosures::DraftSeeds.seed!.find { |d| d.kind == "pay_statements" }
            consents = [ company, other_company ].map do |owner|
              employee = create(:employee, company: owner)
              user = create(:user, company: owner, role: "portal_employee")
              link = EmployeeAccountLink.create!(company: owner, employee: employee, user: user, status: "active")
              DeliveryConsent.create!(
                company: owner, user: user, employee: employee, employee_account_link: link,
                delivery_disclosure: disclosure, kind: "pay_statements",
                disclosure_version: disclosure.version, disclosure_digest: disclosure.digest,
                given_at: Time.current, method: "employee_portal_checkbox"
              )
            end
            expect do
              connection.transaction(requires_new: true) do
                DeliveryConsent.new(
                  company: company, user: consents.first.user, employee: consents.last.employee,
                  employee_account_link: consents.last.employee_account_link, delivery_disclosure: disclosure,
                  kind: "pay_statements", disclosure_version: disclosure.version, disclosure_digest: disclosure.digest,
                  given_at: 1.minute.ago, withdrawn_at: Time.current, method: "employee_portal_checkbox"
                ).save!(validate: false)
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            expect do
              connection.transaction(requires_new: true) do
                DeliveryConsent.new(
                  company: company, user: consents.first.user, employee: consents.first.employee,
                  employee_account_link: consents.last.employee_account_link, delivery_disclosure: disclosure,
                  kind: "pay_statements", disclosure_version: disclosure.version, disclosure_digest: disclosure.digest,
                  given_at: 1.minute.ago, withdrawn_at: Time.current, method: "employee_portal_checkbox"
                ).save!(validate: false)
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            setup_step_three(connection, tables: %w[delivery_consents], read_tables: %w[delivery_disclosures])
            consents
          end

          TenantScope.with_company(company.id) do
            expect(DeliveryConsent.order(:id).pluck(:id)).to eq([ own.id ])
            expect(DeliveryConsent.where(id: foreign.id).update_all(withdrawn_at: Time.current)).to eq(0)
            expect(DeliveryConsent.where(id: foreign.id).delete_all).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                DeliveryConsent.insert_all!([
                  foreign.attributes.except("id", "withdrawn_at").merge(
                    "kind" => "w2gu",
                    "access_proof_verified_at" => Time.current,
                    "method" => "employee_portal_pdf_verified"
                  )
                ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    it "isolates employee verification items, commit acknowledgements, and readiness overrides with composite tenant FKs" do
      pool.with_connection do |connection|
        connection.transaction do
          company = create(:company)
          other_company = create(:company, organization: company.organization)
          actor = create(:user, company: company, organization: company.organization, role: "org_admin")

          fixtures = TenantScope.as_system(reason: "Create lifecycle foundation RLS fixtures") do
            rows = [ company, other_company ].map do |owner|
              employee = create(:employee, company: owner)
              period = create(:pay_period, company: owner)
              w4 = EmployeeW4Election.create!(
                EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
                  company: owner, employee: employee, effective_on: period.pay_date,
                  source: "default_withholding", reason: "Default withholding fixture"
                )
              )
              admin_override = AdminOverride.create!(
                company: owner, actor: actor, subject: employee, action: "employee_readiness_override#grant",
                reason: "RLS isolation test override fixture",
                before_snapshot: {}, after_snapshot: {}, preflight_result: {}
              )
              item = EmployeeVerificationItem.create!(
                company: owner, employee: employee, event_kind: "new_hire",
                status: "pending_verification", source_actor: actor
              )
              ack = PayPeriodVerificationAcknowledgement.create!(
                company: owner, pay_period: period, employee_verification_item: item,
                employee: employee, acknowledged_by: actor, acknowledged_at: Time.current,
                item_status_snapshot: "pending_verification", item_updated_at_snapshot: item.updated_at
              )
              override = EmployeeReadinessOverride.create!(
                company: owner, employee: employee, pay_period: period,
                default_w4_election: w4, default_w4_acknowledged: true,
                missing_items_snapshot: [ "tax_form" ],
                reason: "RLS isolation test readiness override",
                granted_by: actor, granted_at: Time.current, admin_override: admin_override
              )
              { company: owner, employee: employee, period: period, w4: w4, admin_override: admin_override, item: item, ack: ack, override: override }
            end

            own, foreign = rows
            expect do
              connection.transaction(requires_new: true) do
                EmployeeVerificationItem.new(company: own[:company], employee: foreign[:employee], event_kind: "new_hire").save!(validate: false)
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            expect do
              connection.transaction(requires_new: true) do
                PayPeriodVerificationAcknowledgement.new(
                  company: own[:company], pay_period: foreign[:period], employee_verification_item: own[:item],
                  employee: own[:employee], acknowledged_by: actor, acknowledged_at: Time.current,
                  item_status_snapshot: "pending_verification", item_updated_at_snapshot: own[:item].updated_at
                ).save!(validate: false)
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)
            expect do
              connection.transaction(requires_new: true) do
                EmployeeReadinessOverride.new(
                  company: own[:company], employee: own[:employee], expires_on: Date.current + 7,
                  default_w4_election: foreign[:w4], reason: "Cross-company W-4 override must fail FK",
                  granted_by: actor, granted_at: Time.current, admin_override: own[:admin_override]
                ).save!(validate: false)
              end
            end.to raise_error(ActiveRecord::InvalidForeignKey)

            setup_step_three(
              connection,
              tables: %w[employee_verification_items pay_period_verification_acknowledgements employee_readiness_overrides],
              read_tables: %w[employees pay_periods employee_w4_elections admin_overrides users]
            )
            rows
          end

          own, foreign = fixtures
          TenantScope.with_company(company.id) do
            expect(EmployeeVerificationItem.pluck(:id)).to eq([ own[:item].id ])
            expect(EmployeeVerificationItem.where(id: foreign[:item].id).update_all(status: "verified")).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                EmployeeVerificationItem.insert_all!([ {
                  company_id: other_company.id, employee_id: foreign[:employee].id,
                  event_kind: "profile_change", status: "pending_verification",
                  created_at: Time.current, updated_at: Time.current
                } ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }

            expect(PayPeriodVerificationAcknowledgement.pluck(:id)).to eq([ own[:ack].id ])
            expect(PayPeriodVerificationAcknowledgement.where(id: foreign[:ack].id).delete_all).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                PayPeriodVerificationAcknowledgement.insert_all!([ {
                  company_id: other_company.id, pay_period_id: foreign[:period].id,
                  employee_verification_item_id: foreign[:item].id, employee_id: foreign[:employee].id,
                  acknowledged_by_id: actor.id, acknowledged_at: Time.current,
                  item_status_snapshot: "pending_verification", item_updated_at_snapshot: foreign[:item].updated_at,
                  created_at: Time.current, updated_at: Time.current
                } ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }

            expect(EmployeeReadinessOverride.pluck(:id)).to eq([ own[:override].id ])
            expect(EmployeeReadinessOverride.where(id: foreign[:override].id).update_all(revoke_reason: "tampered")).to eq(0)
            expect do
              connection.transaction(requires_new: true) do
                EmployeeReadinessOverride.insert_all!([ {
                  company_id: other_company.id, employee_id: foreign[:employee].id,
                  expires_on: Date.current + 7, reason: "Cross-tenant insert must fail RLS",
                  granted_by_id: actor.id, granted_at: Time.current,
                  admin_override_id: foreign[:admin_override].id,
                  created_at: Time.current, updated_at: Time.current
                } ])
              end
            end.to raise_error(ActiveRecord::StatementInvalid) { |error| expect(error.cause).to be_a(PG::InsufficientPrivilege) }
          end
          raise ActiveRecord::Rollback
        end
      end
    end

    [ [ true, "SELECT" ], [ false, "SELECT, UPDATE" ] ].each do |bypass, privileges|
      it "rejects runtime role capabilities bypass=#{bypass} and grants=#{privileges}" do
        pool.with_connection do |connection|
          connection.transaction do
            setup_step_three(connection, tables: [], bypass: bypass, switch_privileges: privileges)
            expect { RlsDatabase.verify_runtime!(connection) }.to raise_error(/non-bypass payroll_app role/)
            raise ActiveRecord::Rollback
          end
        end
      end
    end

    def rule_attributes
      {
        component_key: "bonus", display_name: "Bonus", component_kind: "earning",
        fit_treatment: "taxable", social_security_treatment: "taxable", medicare_treatment: "taxable",
        additional_medicare_treatment: "taxable", swica_treatment: "included", retirement_treatment: "included",
        reimbursement_treatment: "not_applicable", effective_from: Date.new(2026, 1, 1), source_name: "Policy fixture", version: "1"
      }
    end

    def setup_step_three(connection, tables: %w[departments], bypass: false, switch_privileges: "SELECT", read_tables: [], decision_function: true)
      bypass_clause = bypass ? "BYPASSRLS" : "NOBYPASSRLS"
      # Roles are cluster-wide; a local PostgreSQL cluster may already have payroll_app.
      connection.execute(<<~SQL)
        DO $$ BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'payroll_app') THEN
            CREATE ROLE payroll_app NOSUPERUSER #{bypass_clause};
          ELSE
            ALTER ROLE payroll_app NOSUPERUSER #{bypass_clause};
          END IF;
        END $$
      SQL
      connection.execute("GRANT USAGE ON SCHEMA public, rls_admin TO payroll_app")
      # As rls_runtime_role.sql grants it in production.
      connection.execute("GRANT EXECUTE ON FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} TO payroll_app") if decision_function
      read_tables.each { |table| connection.execute("GRANT SELECT ON #{connection.quote_table_name(table)} TO payroll_app") }
      tables.each do |table|
        quoted = connection.quote_table_name(table)
        connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON #{quoted} TO payroll_app")
        connection.execute("ALTER TABLE #{quoted} ENABLE ROW LEVEL SECURITY")
        connection.execute("ALTER TABLE #{quoted} FORCE ROW LEVEL SECURITY")
      end
      connection.execute("GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO payroll_app")
      connection.execute("REVOKE ALL ON rls_admin.rls_kill_switch FROM payroll_app")
      connection.execute("GRANT #{switch_privileges} ON rls_admin.rls_kill_switch TO payroll_app")
      connection.execute("SET LOCAL ROLE payroll_app")
    end
  end
end
