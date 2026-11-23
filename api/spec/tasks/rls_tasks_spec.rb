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

  it "summarizes only the guard's structured events" do
    warning = '{"event":"rls_missing_context","call_site":"app/sample.rb:1","tables":["departments"]}'
    allow($stdin).to receive(:each_line).and_yield("noise").and_yield("{invalid").and_yield("WARN #{warning}").and_yield(warning)
    expect { invoke("rls:shadow_report") }.to output(/"event": "rls_missing_context".*"count": 2/m).to_stdout
  end
end
