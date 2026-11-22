# frozen_string_literal: true

namespace :compensation do
  desc "Fail when code writes pay rates or compensation history outside EmployeeCompensationChangeService"
  task lint_writes: :environment do
    require Rails.root.join("lib/compensation_write_lint")
    offenses = CompensationWriteLint.offenses
    if offenses.any?
      warn "Pay rates change only through EmployeeCompensationChangeService (M3-4):"
      offenses.each { |offense| warn "  #{offense}" }
      abort "#{offenses.size} compensation write-path offense(s)"
    end
    puts "Compensation write path clean"
  end

  desc "Refresh pay-rate cache columns from the versions in effect today"
  task sync_effective: :environment do
    SyncEffectiveCompensationJob.perform_now
    puts "Compensation cache refreshed"
  end
end
