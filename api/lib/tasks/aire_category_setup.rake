# frozen_string_literal: true

namespace :aire_rollout do
  desc "Audited, unpublished company2 AIRE category and historical-attribution setup"
  task configure_categories: :environment do
    puts TimeTracking::AireCategorySetup.call!(source: TimeTrackingSource.find(ENV.fetch("SOURCE_ID")),
      actor: User.find(ENV.fetch("ACTOR_ID")), reason: ENV.fetch("REASON"), evidence: ENV.fetch("EVIDENCE")).to_json
  end
end
