# frozen_string_literal: true

namespace :aire_rollout do
  def load_verified_rollout
    sha = ENV.fetch("AIRE_ROLLOUT_MANIFEST_SHA256")
    manifest = if ENV["AIRE_ROLLOUT_MANIFEST_PATH"].present?
      TimeTracking::VerifiedHistoryRollout.load_file!(
        path: ENV.fetch("AIRE_ROLLOUT_MANIFEST_PATH"), expected_sha256: sha
      )
    else
      TimeTracking::VerifiedHistoryRollout.load_encrypted_file!(
        path: Rails.root.join("config/aire_verified_history_rollout.enc.json"),
        key_hex: ENV.fetch("AIRE_ROLLOUT_MANIFEST_KEY"), expected_sha256: sha
      )
    end
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
      unless ENV["AIRE_ROLLOUT_PRODUCTION_APPROVED"] == "yes" && ENV["AIRE_ROLLOUT_RELEASE_ID"].present?
        raise "Production AIRE history rollout requires an approved release ID and explicit approval"
      end
    else
      database = ActiveRecord::Base.connection_db_config.database.to_s
      unless ENV["AIRE_ROLLOUT_LOCAL_TEST"] == "1" && database.include?("_rollout_rehearsal_")
        raise "AIRE history rollout writes are allowed only in a named local rehearsal database"
      end
    end

    puts "AIRE rollout applied: #{load_verified_rollout.apply!.to_json}"
  end

  desc "Fail closed if the verified AIRE history has not been reconciled"
  task ensure_complete: :environment do
    expected_sha256 = ENV.fetch("AIRE_ROLLOUT_MANIFEST_SHA256").downcase
    company = Company.find_by(id: 2)
    if company
      raise "AIRE rollout company identity changed" unless company.name == "AIRE Services"

      source = company.time_tracking_sources.find_by(id: 1, source_type: "aire_services")
      raise "AIRE rollout source identity changed" unless source
      unless AireVerifiedHistoryRolloutReceipt.exists?(
        company: company, time_tracking_source: source, manifest_sha256: expected_sha256
      )
        raise "Verified AIRE history has not been applied; provide the approved private manifest before deployment"
      end
    end
  end
end
