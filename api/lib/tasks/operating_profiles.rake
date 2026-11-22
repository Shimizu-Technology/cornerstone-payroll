# frozen_string_literal: true

namespace :operating_profiles do
  desc "Read-only parity check comparing persisted current operating profiles with legacy company configuration"
  task parity: :environment do
    result = ClientOperatingProfiles::ParityChecker.call
    result.differences.each do |diff|
      puts "DIFF  company_id=#{diff.company_id} name=#{diff.company_name.inspect} field=#{diff.field}"
    end

    if result.passed?
      puts "OK    operating_profiles:parity checked=#{result.checked_count} skipped_test_workspaces=#{result.skipped_test_workspace_count} differences=0"
    else
      abort "FAIL  operating_profiles:parity checked=#{result.checked_count} skipped_test_workspaces=#{result.skipped_test_workspace_count} differences=#{result.differences.length}"
    end
  end
end
