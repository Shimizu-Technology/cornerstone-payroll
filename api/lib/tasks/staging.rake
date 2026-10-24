# frozen_string_literal: true

namespace :staging do
  desc "Verify staging containment and local durable dependencies without contacting providers"
  task readiness: :environment do
    abort "Requires DEPLOYMENT_ENV=staging" unless StagingOutboundPolicy.staging?
    report = StagingReadiness.new.run(live: true)
    puts JSON.generate(report.as_json)
    abort "Staging readiness failed" unless report.passed?
  end

  namespace :clone do
    desc "Quarantine clone jobs, pending dispatch and tokens (dry-run unless APPLY=true)"
    task quarantine: :environment do
      puts JSON.generate(StagingCloneContainment.new.quarantine(apply: ENV["APPLY"] == "true"))
    end

    desc "Rebind named testers and staging integration credentials (dry-run unless APPLY=true)"
    task configure: :environment do
      puts JSON.generate(StagingCloneContainment.new.configure(apply: ENV["APPLY"] == "true"))
    end

    desc "Read-only clone containment verification; counts only"
    task verify: :environment do
      puts JSON.generate(StagingCloneContainment.new.counts)
    end
  end
end
