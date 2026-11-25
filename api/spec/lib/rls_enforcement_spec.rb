# frozen_string_literal: true

require "rails_helper"

RSpec.describe RlsEnforcement do
  let(:connection) { ActiveRecord::Base.connection }
  let(:out) { StringIO.new }

  it "orders every protected table once, with the busiest payroll tables last" do
    expect(described_class.ordered_tables).to match_array(RlsTables::PROTECTED_TABLES.to_a)
    expect(described_class.ordered_tables.last(described_class::CORE_TABLES.size)).to eq(described_class::CORE_TABLES)
    expect(described_class.select_tables("departments, employee_notes")).to eq(%w[employee_notes departments])
    expect { described_class.select_tables("departments companies") }.to raise_error(ArgumentError, /companies/)
    expect { described_class.select_tables(" , ") }.to raise_error(ArgumentError, /TABLES is empty/)
  end

  it "finds no prerequisite failure on a staged database apart from the runtime role it is given" do
    allow(described_class).to receive(:runtime_role_ready?).and_return(true)
    expect(described_class.preflight_failures(connection)).to be_empty

    connection.execute("ALTER TABLE department_ytd_totals ALTER COLUMN company_id DROP NOT NULL")
    connection.execute("UPDATE #{RlsDatabase::SWITCH} SET bypass_enabled = true WHERE singleton")
    connection.execute("DROP POLICY company_isolation ON employee_notes")
    expect(described_class.preflight_failures(connection)).to contain_exactly(
      "the kill switch is bypassing",
      "policies are not staged on: employee_notes",
      "company_id is still nullable on department_ytd_totals; deploy the contract migration first"
    )
  end

  it "accepts only a non-bypass runtime role with SELECT-only kill switch access" do
    connection.execute(<<~SQL)
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'payroll_app') THEN
          CREATE ROLE payroll_app NOSUPERUSER NOBYPASSRLS;
        END IF;
      END $$
    SQL
    connection.execute("GRANT USAGE ON SCHEMA rls_admin TO payroll_app")
    connection.execute("REVOKE ALL ON #{RlsDatabase::SWITCH} FROM payroll_app")
    expect(described_class.runtime_role_ready?(connection)).to be(false)
    connection.execute("GRANT SELECT ON #{RlsDatabase::SWITCH} TO payroll_app")
    expect(described_class.runtime_role_ready?(connection)).to be(true)
    connection.execute("GRANT UPDATE ON #{RlsDatabase::SWITCH} TO payroll_app")
    expect(described_class.runtime_role_ready?(connection)).to be(false)
  end

  it "retries a locked table, reports it and moves on to the next table" do
    stub_const("#{described_class}::LOCK_TIMEOUT", "50ms")
    sleeps = []
    blocker = PG.connect(connection.pool.db_config.url)
    blocker.exec("BEGIN; LOCK TABLE employee_notes IN ACCESS SHARE MODE")

    failed = described_class.enforce!(connection, %w[employee_notes departments], batch_size: 1, pause: 2,
      out: out, sleeper: ->(seconds) { sleeps << seconds })
    expect(failed).to eq(%w[employee_notes])
    expect(out.string.scan("Lock timeout on employee_notes").size).to eq(described_class::ATTEMPTS)
    expect(out.string).to include("Batch 2/2: departments", "Enforced RLS on departments")
    expect(sleeps).to eq([ 1, 2, 2 ])
    expect(described_class.pending(connection, %w[employee_notes departments])).to eq(%w[employee_notes])
    expect(described_class.verification(connection, %w[employee_notes departments])).to include(
      "enforced_tables" => 1, "selected_not_enforced" => %w[employee_notes], "all_enforced" => false, "kill_switch_bypass" => false
    )
  ensure
    blocker&.close
  end

  it "stops before the next table once the kill switch is set" do
    allow(RlsDatabase).to receive(:kill_switch).and_return(false, true)

    expect { described_class.enforce!(connection, %w[employee_notes departments], out: out) }
      .to raise_error(described_class::Stopped, /stopped before departments/)
    expect(described_class.pending(connection, %w[employee_notes departments])).to eq(%w[departments])
  end
end
