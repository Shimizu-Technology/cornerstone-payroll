# frozen_string_literal: true

# Contains no external-provider readiness requests. ProductionReadiness keeps its
# original live checks for every deployment other than DEPLOYMENT_ENV=staging.
class StagingReadiness
  def initialize(env: ENV)
    @env = env
  end

  def run(live: Rails.env.production?)
    checks = [ check("staging containment settings") { StagingOutboundPolicy.validate!(env: @env) } ]
    checks << check("complete Solid Queue schema exists") { StagingCloneContainment.queue_schema_complete? }
    checks << check("Solid Queue is the effective durable job adapter") { ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::SolidQueueAdapter) }
    checks << check("staging queue execution ownership matches the selected topology") { @env["USE_SOLID_QUEUE"] == "true" && @env["SOLID_QUEUE_IN_PUMA"] != "true" }
    checks << check("staging clone containment manifest exists") { StagingQuarantine.complete? }
    if live
      checks.concat([
        check("primary database accepts a query") { ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1 },
        check("all database migrations are current") { DatabaseMigrationStatus.current? },
        check("persisted encrypted data can be decrypted") { decryptable? },
        check("Solid Queue worker has a recent heartbeat") { SolidQueue::Process.where(kind: "Worker", last_heartbeat_at: 5.minutes.ago..).exists? }
      ])
    end
    if live && RlsConfiguration.runtime_url(@env)
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        checks << check("RLS runtime role and kill switch privileges") { RlsDatabase.verify_runtime!(connection) }
        checks << check("RLS policy installation matches the selected phase") do
          RlsDatabase.expected_phase?(connection, enforced: @env["RLS_EXPECT_ENFORCED"] == "true")
        end
        checks << check("Cross-company login link decision is a restricted SECURITY DEFINER function") do
          RlsDatabase.login_link_decision_ready?(connection)
        end
        if @env["RLS_EXPECT_ENFORCED"] == "true"
          checks << check("RLS kill switch is off") { RlsDatabase.kill_switch(connection) == false }
        end
      end
    end
    ProductionReadiness::Report.new(checks: checks, connected_payroll: ConnectedPayrollMode.capability(env: @env))
  end

  private

  def check(name)
    passed = yield == true
    ProductionReadiness::Check.new(name: name, passed: passed, detail: passed ? "verified" : "not verified")
  rescue StandardError => error
    ProductionReadiness::Check.new(name: name, passed: false, detail: "#{error.class.name} while verifying")
  end

  def decryptable?
    EncryptedDataReadiness.verify!
  end
end
