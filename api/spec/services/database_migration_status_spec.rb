# frozen_string_literal: true

require "rails_helper"

RSpec.describe DatabaseMigrationStatus do
  let(:primary) { ActiveRecord::Base.connection_db_config }

  def secondary_config(migrations_paths)
    ActiveRecord::DatabaseConfigurations::HashConfig.new(
      primary.env_name, "migration_status_secondary", primary.configuration_hash.merge(migrations_paths: migrations_paths)
    )
  end

  def with_extra_config(db_config)
    allow(ActiveRecord::Base.configurations).to receive(:configs_for).and_wrap_original do |original, **options|
      configs = original.call(**options)
      options.keys == [ :env_name ] ? [ *configs, db_config ] : configs
    end
    yield
  end

  it "checks every database without replacing the primary pool" do
    pool = ActiveRecord::Base.connection_pool
    handler = ActiveRecord::Base.connection_handler

    with_extra_config(secondary_config(primary.migrations_paths || "db/migrate")) do
      expect(described_class.current?).to be(true)
    end
    expect(ActiveRecord::Base.connection_pool).to equal(pool)
    expect(handler.retrieve_connection_pool("DatabaseMigrationStatus::migration_status_secondary")).to be_nil
  end

  it "keeps a temporary pool off the shared connection handler while it is in use" do
    shared = ActiveRecord::Base.connection_handler
    seen = []
    allow_any_instance_of(ActiveRecord::MigrationContext).to receive(:needs_migration?).and_wrap_original do |original|
      seen << shared.connection_pool_list.map { |pool| pool.db_config.name }
      original.call
    end

    with_extra_config(secondary_config(primary.migrations_paths || "db/migrate")) do
      expect(described_class.current?).to be(true)
    end
    expect(seen).not_to be_empty
    expect(seen.flatten).not_to include("migration_status_secondary")
  end

  it "reports a database whose migrations have not all run" do
    Dir.mktmpdir("pending-migrations") do |path|
      File.write(File.join(path, "20000101000000_readiness_pending_probe.rb"),
        "class ReadinessPendingProbe < ActiveRecord::Migration[8.1]; end\n")

      with_extra_config(secondary_config(path)) do
        expect(described_class.current?).to be(false)
      end
    end
  end
end
