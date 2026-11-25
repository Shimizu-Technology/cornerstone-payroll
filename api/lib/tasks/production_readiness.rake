# frozen_string_literal: true

require_relative "../rls_task"

namespace :production do
  desc "Fail unless production configuration and live durable dependencies are ready"
  RlsTask.system readiness: :environment do
    report = ProductionReadiness.new.run(live: Rails.env.production?)
    report.checks.each do |check|
      puts "#{check.status}  #{check.name} (#{check.detail})"
    end
    puts "EVIDENCE #{JSON.generate(report.as_json)}"

    abort "Production readiness failed (#{report.failures.length} control(s))." unless report.passed?

    warning_count = report.warnings.length
    summary = " (#{warning_count} #{'warning'.pluralize(warning_count)})" if warning_count.positive?
    if StagingOutboundPolicy.staging?
      puts "Staging containment and durable dependency profile passed#{summary}; production provider probes were not run."
    else
      puts "Production configuration and live dependency probes passed#{summary}. Complete the manual evidence checklist before release."
    end
  end
end
