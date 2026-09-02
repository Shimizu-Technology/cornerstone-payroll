# frozen_string_literal: true

require "rails_helper"
require "rake"
require "yaml"
require Rails.root.join("lib/database_predeploy")
require Rails.root.join("lib/kamal_migration_executor")

RSpec.describe "database pre-deploy safety" do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:clear_advisory_locks")
    Rake::Task["db:clear_advisory_locks"].reenable
  end

  it "never terminates database sessions while preparing a deploy" do
    expect(ActiveRecord::Base).not_to receive(:connection)
    expect(ActiveRecord::Base).not_to receive(:connection_pool)

    expect { Rake::Task["db:clear_advisory_locks"].invoke }
      .to raise_error(SystemExit, /terminating shared database sessions is unsafe/)
  end

  it "keeps schema preparation out of the runtime entrypoint" do
    entrypoint = Rails.root.join("bin/docker-entrypoint").read

    expect(entrypoint).to include('exec "${@}"')
    expect(entrypoint).not_to match(/db:(?:prepare|safe_prepare)|solid_queue:setup/)
  end

  it "runs Kamal schema preparation once without exposing direct URLs to runtime containers" do
    deploy_config = YAML.safe_load(Rails.root.join("config/deploy.yml").read, aliases: true)
    runtime_secrets = deploy_config.dig("env", "secret")
    migration_keys = %w[
      MIGRATION_DATABASE_URL
      MIGRATION_CACHE_DATABASE_URL
      MIGRATION_QUEUE_DATABASE_URL
      MIGRATION_CABLE_DATABASE_URL
    ]
    hook_path = Rails.root.join(".kamal/hooks/pre-deploy")
    hook = hook_path.read
    migration_runner_path = Rails.root.join("bin/kamal-safe-prepare")
    migration_runner = migration_runner_path.read
    common_secrets = Rails.root.join(".kamal/secrets-common").read
    default_secrets = Rails.root.join(".kamal/secrets").read

    expect(runtime_secrets).not_to include(*migration_keys)
    expect(hook_path).to be_executable
    expect(migration_runner_path).to be_executable
    expect(hook.scan("kamal-safe-prepare").length).to eq(1)
    expect(migration_runner).to include("KamalMigrationExecutor.new.run!")
    expect(common_secrets).to include(*migration_keys)
    expect(default_secrets).not_to include(*migration_keys)
  end

  it "passes migration secrets to a destination run without exposing them in rendered commands" do
    secret_url = "postgresql://migration-user:secret@example.test/payroll"
    environment = {
      "KAMAL_VERSION" => "release-sha",
      "KAMAL_DESTINATION" => "production",
      "MIGRATION_DATABASE_URL" => secret_url
    }
    cli = class_double(Kamal::Cli::Main)
    executor = KamalMigrationExecutor.new(environment: environment, cli: cli)
    expected_arguments =
      %w[app exec --quiet --primary --version release-sha --destination production --] + [ "bin/rails db:safe_prepare" ]
    expect(cli).to receive(:start).with(expected_arguments)

    executor.run!
    sensitive_environment = KamalMigrationExecutor.migration_environment
    app_execution = Class.new do
      attr_reader :options

      def initialize
        @options = {}
      end

      def exec(*)
        options.fetch(:env)
      end
    end
    app_execution.prepend(KamalMigrationExecutor::InjectEnvironment)
    injected_environment = app_execution.new.exec("bin/rails db:safe_prepare")
    rendered_argument = Kamal::Utils.argumentize("--env", injected_environment).last

    expect(executor.command_arguments).to eq(expected_arguments)
    expect(executor.command_arguments.join(" ")).not_to include(secret_url)
    expect(injected_environment).to eq(sensitive_environment)
    expect(injected_environment.fetch("MIGRATION_DATABASE_URL")).to eq(secret_url)
    expect(rendered_argument.to_s).to include(secret_url)
    expect(rendered_argument.inspect).to include("MIGRATION_DATABASE_URL=[REDACTED]")
    expect(rendered_argument.inspect).not_to include(secret_url)
  end
end

RSpec.describe DatabasePredeploy do
  let(:pooled_url) { "postgresql://payroll:secret@example-pooler.us-east-2.aws.neon.tech/payroll?sslmode=require" }
  let(:direct_url) { "postgresql://payroll:secret@example.us-east-2.aws.neon.tech/payroll?sslmode=require" }

  it "fails closed when production uses a pooled application URL without a direct migration URL" do
    predeploy = described_class.new(
      env: { "RAILS_ENV" => "production", "DATABASE_URL" => pooled_url },
      command_runner: ->(*) { raise "must not run" }
    )

    expect { predeploy.run! }.to raise_error(
      described_class::ConfigurationError,
      /MIGRATION_DATABASE_URL must be configured with a direct, non-pooler connection/
    )
  end

  it "rejects a pooled migration URL" do
    predeploy = described_class.new(
      env: {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => pooled_url,
        "MIGRATION_DATABASE_URL" => pooled_url
      },
      command_runner: ->(*) { raise "must not run" }
    )

    expect { predeploy.run! }.to raise_error(
      described_class::ConfigurationError,
      /must use a direct connection/
    )
  end

  it "rejects a malformed or non-PostgreSQL migration URL" do
    predeploy = described_class.new(
      env: {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => pooled_url,
        "MIGRATION_DATABASE_URL" => "https://example.com/not-a-database"
      },
      command_runner: ->(*) { raise "must not run" }
    )

    expect { predeploy.run! }.to raise_error(
      described_class::ConfigurationError,
      /must be a valid PostgreSQL connection URL/
    )
  end

  it "rejects Supabase-style pooled hosts and port-based PgBouncer URLs" do
    pooled_urls = [
      "postgresql://payroll:secret@aws-0-us-east-1.pooler.supabase.com/payroll",
      "postgresql://payroll:secret@db.example.com:6543/payroll"
    ]

    pooled_urls.each do |migration_url|
      predeploy = described_class.new(
        env: {
          "RAILS_ENV" => "production",
          "DATABASE_URL" => pooled_url,
          "MIGRATION_DATABASE_URL" => migration_url
        },
        command_runner: ->(*) { raise "must not run" }
      )

      expect { predeploy.run! }.to raise_error(
        described_class::ConfigurationError,
        /must use a direct connection/
      )
    end
  end

  it "runs every schema task through the direct migration URL" do
    calls = []
    predeploy = described_class.new(
      env: {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => pooled_url,
        "MIGRATION_DATABASE_URL" => direct_url
      },
      app_root: "/app/api",
      command_runner: ->(*args) { calls << args }
    )

    predeploy.run!

    expect(calls.map { |call| call.drop(2) }).to eq([ %w[db:prepare], %w[solid_queue:setup] ])
    calls.each do |environment, command, *_task|
      expect(command).to eq("/app/api/bin/rails")
      expect(environment).to include(
        "DATABASE_URL" => direct_url,
        "CACHE_DATABASE_URL" => direct_url,
        "QUEUE_DATABASE_URL" => direct_url,
        "CABLE_DATABASE_URL" => direct_url,
        "PGCONNECT_TIMEOUT" => "10",
        "PGOPTIONS" => include("lock_timeout=10s", "statement_timeout=15min")
      )
    end
  end

  it "requires an explicit migration connection for every production deployment" do
    predeploy = described_class.new(
      env: { "RAILS_ENV" => "production", "DATABASE_URL" => direct_url },
      command_runner: ->(*) { raise "must not run" }
    )

    expect { predeploy.run! }.to raise_error(
      described_class::ConfigurationError,
      /MIGRATION_DATABASE_URL must be configured/
    )
  end

  it "does not allow ambient settings to remove migration timeout bounds" do
    predeploy = described_class.new(
      env: {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => pooled_url,
        "MIGRATION_DATABASE_URL" => direct_url,
        "PGCONNECT_TIMEOUT" => "0",
        "PGOPTIONS" => ""
      }
    )

    expect(predeploy.migration_environment).to include(
      "PGCONNECT_TIMEOUT" => "10",
      "PGOPTIONS" => include(
        "lock_timeout=10s",
        "statement_timeout=15min",
        "idle_in_transaction_session_timeout=5min"
      )
    )
  end

  it "inherits a distinct direct service database without replacing it" do
    cache_url = "postgresql://payroll:secret@cache.example.com/cache"
    predeploy = described_class.new(
      env: {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => pooled_url,
        "CACHE_DATABASE_URL" => cache_url,
        "MIGRATION_DATABASE_URL" => direct_url
      }
    )

    expect(predeploy.migration_environment).not_to have_key("CACHE_DATABASE_URL")
  end

  it "uses a direct migration override for a distinct pooled service database" do
    pooled_cache_url = "postgresql://payroll:secret@cache-pooler.example.com/cache"
    direct_cache_url = "postgresql://payroll:secret@cache.example.com/cache"
    predeploy = described_class.new(
      env: {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => pooled_url,
        "MIGRATION_DATABASE_URL" => direct_url,
        "CACHE_DATABASE_URL" => pooled_cache_url,
        "MIGRATION_CACHE_DATABASE_URL" => direct_cache_url
      }
    )

    expect(predeploy.migration_environment).to include(
      "DATABASE_URL" => direct_url,
      "CACHE_DATABASE_URL" => direct_cache_url
    )
  end

  it "uses the normal Rails database configuration outside production when no URL override is needed" do
    calls = []
    predeploy = described_class.new(
      env: { "RAILS_ENV" => "test" },
      app_root: "/app/api",
      command_runner: ->(*args) { calls << args }
    )

    predeploy.run!

    expect(calls).to all(start_with({}, "/app/api/bin/rails"))
  end
end
