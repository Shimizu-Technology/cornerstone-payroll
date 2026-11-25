# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "RLS owner tasks", :rls do
  self.use_transactional_tests = false

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("rls:install")
  end

  def invoke(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  def with_migration_url
    prior = ENV["MIGRATION_DATABASE_URL"]
    ENV["MIGRATION_DATABASE_URL"] = ActiveRecord::Base.connection_db_config.url
    yield
  ensure
    ENV["MIGRATION_DATABASE_URL"] = prior
  end

  it "installs staged policies through the direct owner URL and reports their status" do
    expect { invoke("rls:install") }.to raise_error(SystemExit)
    allow(RlsContextGuard).to receive(:mode).and_return("off")

    transactions = []
    observe = lambda do |event|
      sql = event.payload[:sql]
      transactions << event.payload[:transaction] if sql.start_with?("SELECT pg_temp.install_company_policy")
    end
    with_migration_url do
      ActiveSupport::Notifications.subscribed(observe, "sql.active_record") { invoke("rls:install") }
    end
    expect(transactions.size).to eq(RlsTables::PROTECTED_TABLES.size)
    expect(transactions).not_to include(nil)
    expect(transactions.uniq.size).to eq(RlsTables::PROTECTED_TABLES.size)
    expect { invoke("rls:status") }.to output(/"table": "pay_component_tax_rules",\s+"enabled": false,\s+"forced": false,\s+"policy": true/).to_stdout
    expect { invoke("rls:status") }.to output(/"login_link_decision": \{\s+"installed": true,\s+"security_definer": true/).to_stdout
  end

  it "disables enforced test policies without removing their staged definitions" do
    pool = ActiveRecord::Base.connection_pool
    pool.with_connection do |connection|
      TenantScope.as_system(reason: "Enable one test-only policy") do
        connection.execute("ALTER TABLE departments ENABLE ROW LEVEL SECURITY")
        connection.execute("ALTER TABLE departments FORCE ROW LEVEL SECURITY")
      end
      with_migration_url { expect { invoke("rls:disable") }.to output(/Disabled RLS on departments/).to_stdout }
      expect(RlsDatabase.table_status(connection).find { |row| row.fetch("table") == "departments" })
        .to include("enabled" => false, "forced" => false, "policy" => true)
    ensure
      TenantScope.as_system(reason: "Restore test-only policy flags") do
        connection.execute("ALTER TABLE departments NO FORCE ROW LEVEL SECURITY")
        connection.execute("ALTER TABLE departments DISABLE ROW LEVEL SECURITY")
      end
    end
  end

  def with_env(values)
    prior = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    prior.each { |key, value| ENV[key] = value }
  end

  def summary
    ActiveRecord::Base.connection_pool.with_connection { |connection| RlsDatabase.enforcement_summary(connection) }
  end

  def restore_shadow!
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      TenantScope.as_system(reason: "Restore shadow flags") do
        connection.execute("UPDATE #{RlsDatabase::SWITCH} SET bypass_enabled = false WHERE singleton")
        RlsTables::PROTECTED_TABLES.each do |table|
          connection.execute("ALTER TABLE #{connection.quote_table_name(table)} NO FORCE ROW LEVEL SECURITY")
          connection.execute("ALTER TABLE #{connection.quote_table_name(table)} DISABLE ROW LEVEL SECURITY")
        end
      end
    end
  end

  describe "rls:enforce" do
    let(:total) { RlsTables::PROTECTED_TABLES.size }

    after { restore_shadow! }

    it "refuses with the guard on, for unknown tables and while prerequisites fail" do
      with_migration_url { expect { invoke("rls:enforce") }.to raise_error(SystemExit, /RLS_CONTEXT_GUARD_MODE=off/) }
      allow(RlsContextGuard).to receive(:mode).and_return("off")
      with_env("TABLES" => "departments,companies") do
        with_migration_url { expect { invoke("rls:enforce") }.to raise_error(SystemExit, /Not RLS-protected tables: companies/) }
      end
      with_env("TABLES" => "") do
        with_migration_url { expect { invoke("rls:enforce") }.to raise_error(SystemExit, /TABLES is empty/) }
      end
      with_env("DRY_RUN" => "yes") do
        with_migration_url { expect { invoke("rls:enforce") }.to raise_error(SystemExit, /DRY_RUN must be 1/) }
      end
      holder = PG.connect(ActiveRecord::Base.connection_db_config.url)
      holder.exec("SELECT pg_advisory_lock(#{RlsConfiguration::OWNER_TASK_LOCK})")
      with_migration_url { expect { invoke("rls:enforce") }.to raise_error(SystemExit, /holds the enforcement lock/) }
      # A dry run never takes the lock, so it can't hold up a rollback.
      allow(RlsEnforcement).to receive(:runtime_role_ready?).and_return(true)
      with_env("DRY_RUN" => "1") do
        with_migration_url { expect { invoke("rls:enforce") }.to output(/Dry run: /).to_stdout }
      end
      # rls:disable waits a bounded time for a live enforce, then says why.
      with_env("LOCK_WAIT" => "1") do
        with_migration_url do
          expect { invoke("rls:disable") }.to raise_error(SystemExit, /still holds the enforcement lock after 1s. Set the kill switch first/)
        end
      end
      holder.close

      ActiveRecord::Base.connection.execute("UPDATE #{RlsDatabase::SWITCH} SET bypass_enabled = true WHERE singleton")
      # Roles are cluster-wide, so whether payroll_app exists depends on the host.
      allow(RlsEnforcement).to receive(:runtime_role_ready?).and_return(false)
      with_migration_url do
        expect { invoke("rls:enforce") }.to raise_error(SystemExit) { |error|
          expect(error.message).to include("Refusing to enforce RLS", "the kill switch is bypassing", "payroll_app must exist")
        }
      end
      expect(summary).to include("phase" => "shadow", "enforced_tables" => 0)
    end

    it "lists pending batches on a dry run, enforces a subset, then all tables, and rolls back with rls:disable" do
      allow(RlsContextGuard).to receive(:mode).and_return("off")
      allow(RlsEnforcement).to receive(:runtime_role_ready?).and_return(true)

      with_env("DRY_RUN" => "1", "BATCH_SIZE" => "50") do
        with_migration_url { expect { invoke("rls:enforce") }.to output(/Dry run: #{total} of #{total} .*\nBatch 1: .*\nBatch 3: /m).to_stdout }
      end
      expect(summary).to include("phase" => "shadow")

      with_env("TABLES" => "departments employee_notes", "BATCH_PAUSE" => "0") do
        with_migration_url do
          expect { invoke("rls:enforce") }.to output(
            /Batch 1\/1: employee_notes, departments.*Enforced RLS on departments.*Selected tables are enabled and forced/m
          ).to_stdout
        end
      end
      expect(summary).to include("phase" => "partial", "enforced_tables" => 2, "enabled_xor_forced" => [])
      expect(summary["not_enforced"].size).to eq(total - 2)
      expect { invoke("rls:status") }.to output(/"enforcement": \{\s+"phase": "partial",\s+"protected_tables": #{total},\s+"enforced_tables": 2/).to_stdout

      with_env("DRY_RUN" => "1") do
        with_migration_url { expect { invoke("rls:enforce") }.to output(/Dry run: #{total - 2} of #{total} /).to_stdout }
      end
      with_env("BATCH_PAUSE" => "0") do
        with_migration_url do
          expect { invoke("rls:enforce") }.to output(/"all_enforced": true.*All protected tables are enabled and forced/m).to_stdout
        end
      end
      expect(summary).to include("phase" => "enforced", "enforced_tables" => total)
      EmployeeAppSwitch::Enforcement.reset_cache!
      expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "enforced", enforced: true, enforced_tables: total)
      expect(EmployeeAppSwitch::Enforcement.verified?).to be(true)

      with_migration_url { expect { invoke("rls:disable") }.to output(/Disabled RLS on employees/).to_stdout }
      expect(summary).to include("phase" => "shadow", "enforced_tables" => 0)
    ensure
      EmployeeAppSwitch::Enforcement.reset_cache!
    end
  end

  it "summarizes only the guard's structured events" do
    warning = '{"event":"rls_missing_context","call_site":"app/sample.rb:1","tables":["departments"]}'
    allow($stdin).to receive(:each_line).and_yield("noise").and_yield("{invalid").and_yield("WARN #{warning}").and_yield(warning)
    expect { invoke("rls:shadow_report") }.to output(/"event": "rls_missing_context".*"count": 2/m).to_stdout
  end
end
