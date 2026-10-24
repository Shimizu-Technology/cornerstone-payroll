# frozen_string_literal: true

# Contains no external-provider readiness requests. ProductionReadiness keeps its
# original live checks for every deployment other than DEPLOYMENT_ENV=staging.
class StagingReadiness
  def initialize(env: ENV)
    @env = env
  end

  def run(live: Rails.env.production?)
    checks = [ check("staging containment settings") { StagingOutboundPolicy.validate!(env: @env) } ]
    checks << check("Solid Queue is the effective durable job adapter") { ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::SolidQueueAdapter) }
    checks << check("staging queue execution ownership matches the selected topology") { @env["USE_SOLID_QUEUE"] == "true" && @env["SOLID_QUEUE_IN_PUMA"] != "true" }
    checks << check("staging clone containment manifest exists") { StagingQuarantine.complete? }
    if live
      checks.concat([
        check("primary database accepts a query") { ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1 },
        check("all database migrations are current") { ActiveRecord::Migration.check_all_pending!; true },
        check("persisted encrypted data can be decrypted") { decryptable? },
        check("Solid Queue worker has a recent heartbeat") { SolidQueue::Process.where(kind: "Worker", last_heartbeat_at: 5.minutes.ago..).exists? }
      ])
    end
    ProductionReadiness::Report.new(checks: checks)
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
