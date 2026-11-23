# frozen_string_literal: true

require_relative "../rls_task"

require "json"

namespace :clerk do
  namespace :jwks do
    desc "Clear this process's RequestPathCache Clerk JWKS entries (cannot flush running Puma workers; restart/redeploy Puma to flush in-memory JWKS)"
    task clear: :environment do
      extra_issuers = [ ENV["ISSUER"], ENV["OLD_ISSUER"] ].compact_blank
      result = ClerkTokenVerifier.clear_jwks_cache!(extra_issuers: extra_issuers)
      puts JSON.generate(
        result.merge(
          note: "JWKS is cached in RequestPathCache (process-local MemoryStore), not Rails.cache. This task only clears the current process and cannot flush running Puma workers; restart or redeploy Puma to flush in-memory JWKS caches."
        )
      )
    end
  end

  namespace :cutover do
    desc "Read-only preflight checks for Clerk production cutover (including zero TOTP enrolled)"
    task preflight: :environment do
      report = ClerkCutover::PreflightService.new.run
      report.checks.each do |check|
        puts "#{check.passed ? 'PASS' : 'FAIL'}  #{check.name} (#{check.detail})"
      end
      puts "PREFLIGHT #{JSON.generate(report.as_json)}"
      abort "Clerk cutover preflight failed (#{report.failures.length} check(s))." unless report.passed?
    end

    desc "Read-only local user inventory (prints counts only; writes OUTPUT=... only when WRITE=true)"
    RlsTask.system inventory: :environment do
      service = ClerkCutover::InventoryService.new
      output_path = ENV["OUTPUT"].presence

      if output_path
        unless ENV["WRITE"] == "true"
          abort "Refusing to write inventory file without WRITE=true."
        end

        summary = service.write!(path: output_path, write: true)
        puts JSON.generate(summary.merge("output_written" => true))
      else
        summary = service.generate.fetch("summary")
        puts JSON.generate(summary.merge("output_written" => false))
      end
    end

    desc "Build clerk migrate import JSON from reviewed INVENTORY and Clerk EXPORT using external_id = dev clerk_id (writes OUTPUT=... only when WRITE=true)"
    RlsTask.system build_import: :environment do
      inventory_path = ENV["INVENTORY"].presence || abort("INVENTORY=/path/to/reviewed_inventory.json is required")
      export_path = ENV["EXPORT"].presence || abort("EXPORT=/path/to/clerk_export.csv is required")
      output_path = ENV["OUTPUT"].presence

      builder = ClerkCutover::ImportBuilder.new(
        inventory: File.read(inventory_path),
        clerk_export: File.read(export_path),
        batch: ENV["BATCH"].presence
      )

      if output_path
        unless ENV["WRITE"] == "true"
          abort "Refusing to write import payload without WRITE=true."
        end

        summary = builder.write!(path: output_path, write: true)
        puts JSON.generate(summary.merge("output_written" => true))
      else
        summary = builder.build.fetch(:summary)
        puts JSON.generate(summary.merge("output_written" => false))
      end
    rescue ClerkCutover::ImportBuilder::ValidationError => e
      abort "Import manifest validation failed: #{e.message}"
    end

    desc "Build sealed email-free re-link manifest strictly by external_id (writes OUTPUT=... only when WRITE=true)"
    task build_manifest: :environment do
      output_path = ENV["OUTPUT"].presence
      inventory_raw = ENV["INVENTORY"].present? ? File.read(ENV["INVENTORY"]) : nil

      target_users = if ENV["TARGET_USERS"].present?
        File.read(ENV["TARGET_USERS"])
      elsif ENV["TARGET_CLERK_SECRET_KEY"].present?
        ClerkCutover::ClerkClient.new(secret_key: ENV["TARGET_CLERK_SECRET_KEY"]).list_users
      else
        abort "Provide TARGET_USERS=/path/to/target_users.json or TARGET_CLERK_SECRET_KEY=sk_live_..."
      end

      builder = ClerkCutover::RelinkManifestBuilder.new(
        target_users: target_users,
        inventory: inventory_raw
      )

      if output_path
        unless ENV["WRITE"] == "true"
          abort "Refusing to write manifest file without WRITE=true."
        end

        summary = builder.write!(path: output_path, write: true)
        puts JSON.generate(summary.merge("output_written" => true))
      else
        summary = builder.build.fetch(:summary)
        puts JSON.generate(summary.merge("output_written" => false))
      end
    rescue ClerkCutover::RelinkManifestBuilder::ValidationError, ClerkCutover::ClerkClient::Error => e
      abort "Re-link manifest build failed: #{e.message}"
    end

    desc "Dry-run Clerk user re-link from a sealed MANIFEST (read-only; never writes)"
    RlsTask.system dry_run: :environment do
      manifest_path = ENV["MANIFEST"].presence || abort("MANIFEST=/path/to/prod_manifest.json is required")
      target_client = ENV["TARGET_CLERK_SECRET_KEY"].present? ? ClerkCutover::ClerkClient.new(secret_key: ENV["TARGET_CLERK_SECRET_KEY"]) : nil

      result = ClerkCutover::RelinkService.new(
        manifest: File.read(manifest_path),
        target_client: target_client,
        allow_partial: ENV["ALLOW_PARTIAL"] == "true"
      ).dry_run

      puts JSON.generate(result.as_json)
      abort "Clerk cutover dry-run failed (#{result.errors.length} error(s))." unless result.passed?
    end

    desc "Apply Clerk user re-link atomically from a sealed MANIFEST (requires APPLY=true and TARGET_CLERK_SECRET_KEY)"
    RlsTask.system apply: :environment do
      abort "Refusing to apply Clerk re-link without APPLY=true." unless ENV["APPLY"] == "true"
      manifest_path = ENV["MANIFEST"].presence || abort("MANIFEST=/path/to/prod_manifest.json is required")
      target_secret = ENV["TARGET_CLERK_SECRET_KEY"].presence || abort("TARGET_CLERK_SECRET_KEY is required to verify target Clerk external_id before apply.")
      target_client = ClerkCutover::ClerkClient.new(secret_key: target_secret)

      result = ClerkCutover::RelinkService.new(
        manifest: File.read(manifest_path),
        target_client: target_client,
        allow_partial: ENV["ALLOW_PARTIAL"] == "true",
        env: ENV,
        source_issuer: ENV["SOURCE_CLERK_ISSUER"].presence,
        confirm_m3_1_deployed: ENV["CONFIRM_M3_1_DEPLOYED"] == "true",
        operator: ENV["OPERATOR"].presence
      ).apply!(confirm: true)

      puts JSON.generate(result.as_json)
      abort "Clerk cutover apply failed (#{result.errors.length} error(s))." unless result.passed?
    end

    desc "Roll back Clerk user re-link atomically from a sealed MANIFEST (refuses to write unless APPLY=true)"
    RlsTask.system rollback: :environment do
      abort "Refusing to roll back Clerk re-link without APPLY=true." unless ENV["APPLY"] == "true"
      manifest_path = ENV["MANIFEST"].presence || abort("MANIFEST=/path/to/prod_manifest.json is required")

      result = ClerkCutover::RelinkService.new(
        manifest: File.read(manifest_path),
        operator: ENV["OPERATOR"].presence
      ).rollback!(confirm: true)

      puts JSON.generate(result.as_json)
      abort "Clerk cutover rollback failed (#{result.errors.length} error(s))." unless result.passed?
    end
  end
end
