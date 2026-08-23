# frozen_string_literal: true

namespace :production do
  desc "Fail unless production configuration and live durable dependencies are ready"
  task readiness: :environment do
    report = ProductionReadiness.new.run(live: Rails.env.production?)
    report.checks.each do |check|
      puts "#{check.passed ? 'PASS' : 'FAIL'}  #{check.name} (#{check.detail})"
    end
    puts "EVIDENCE #{JSON.generate(report.as_json)}"

    abort "Production readiness failed (#{report.failures.length} control(s))." unless report.passed?

    puts "Production configuration and live dependency probes passed. Complete the manual evidence checklist before release."
  end
end
