# frozen_string_literal: true

namespace :aire_rollout do
  desc "Capture an unapproved, private source-evidence packet for individual accounting review"
  task export: :environment do
    source = TimeTrackingSource.find(ENV.fetch("SOURCE_ID"))
    actor = User.find(ENV.fetch("ACTOR_ID"))
    manifest = {
      "version" => 1, "company_id" => source.company_id, "company_name" => source.company.name,
      "source_id" => source.id, "source_instance_id" => source.expected_source_instance_id,
      "actor_id" => actor.id, "history_through_work_date" => ENV.fetch("HISTORY_THROUGH_WORK_DATE"),
      "identity_links" => [], "delivered_checks" => [], "issued_entries" => [],
      "classification_cases" => [], "finalized_batch_entries" => []
    }
    packet = TimeTracking::VerifiedHistoryRollout.new(manifest: manifest, actor: actor).capture_review_packet!
    bytes = JSON.pretty_generate(packet) + "\n"
    File.open(ENV.fetch("AIRE_ROLLOUT_EXPORT_PATH"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    puts({ entries_requiring_review: packet.fetch("reviewed_dispositions").length,
      manifest_sha256: Digest::SHA256.hexdigest(bytes), history_coverage_verified: false }.to_json)
  end

  def load_verified_rollout
    sha = ENV.fetch("AIRE_ROLLOUT_MANIFEST_SHA256")
    manifest = TimeTracking::VerifiedHistoryRollout.load_file!(
      path: ENV.fetch("AIRE_ROLLOUT_MANIFEST_PATH"), expected_sha256: sha
    )
    actor = User.find(manifest.fetch("actor_id"))
    TimeTracking::VerifiedHistoryRollout.new(manifest: manifest, actor: actor)
  end

  desc "Read-only preflight for a private, checksummed AIRE history rollout manifest"
  task preview: :environment do
    puts "AIRE rollout preflight: #{load_verified_rollout.preview!.to_json}"
  end

  desc "Apply a preflighted AIRE history rollout; requires explicit release approval"
  task apply: :environment do
    if Rails.env.production?
      unless ENV["AIRE_ROLLOUT_PRODUCTION_APPROVED"] == "yes" && ENV["AIRE_ROLLOUT_RELEASE_ID"].present? && ENV["AIRE_ROLLOUT_RELEASE_OWNER"].present? &&
             ENV["AIRE_ROLLOUT_ACCEPTED_MANIFEST_SHA256"].to_s.downcase == ENV.fetch("AIRE_ROLLOUT_MANIFEST_SHA256").downcase
        raise "Production AIRE history rollout requires an approved release ID and explicit approval"
      end
    else
      database = ActiveRecord::Base.connection_db_config.database.to_s
      unless ENV["AIRE_ROLLOUT_LOCAL_TEST"] == "1" && database.include?("_rollout_rehearsal_")
        raise "AIRE history rollout writes are allowed only in a named local rehearsal database"
      end
    end

    puts "AIRE rollout applied: #{load_verified_rollout.apply!(accepted_manifest_sha256: ENV["AIRE_ROLLOUT_ACCEPTED_MANIFEST_SHA256"], release_owner: ENV["AIRE_ROLLOUT_RELEASE_OWNER"]).to_json}"
  end

  desc "Fail closed if the verified AIRE history has not been reconciled"
  task ensure_complete: :environment do
    expected_sha256 = ENV.fetch("AIRE_ROLLOUT_MANIFEST_SHA256").downcase
    rollout = load_verified_rollout
    unless rollout.preview!.fetch(:history_coverage_verified) == true
      raise "Fresh AIRE historical coverage is incomplete; the prior receipt cannot authorize completion"
    end
    manifest = TimeTracking::VerifiedHistoryRollout.load_file!(
      path: ENV.fetch("AIRE_ROLLOUT_MANIFEST_PATH"), expected_sha256: expected_sha256
    )
    source = TimeTrackingSource.find(manifest.fetch("source_id"))
    unless source.historical_reconciliation_complete? && AireVerifiedHistoryRolloutReceipt.exists?(
      coverage_verified: true, source_instance_id: source.expected_source_instance_id,
      company_id: manifest.fetch("company_id"), time_tracking_source_id: manifest.fetch("source_id"),
      manifest_sha256: expected_sha256
    )
      raise "Verified AIRE history has not been applied; provide the approved private manifest before deployment"
    end
  end
end
