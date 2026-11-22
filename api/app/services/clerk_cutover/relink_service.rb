# frozen_string_literal: true

require "digest"
require "json"

module ClerkCutover
  # Dry-run, atomic apply, and atomic rollback for one-time Payroll user
  # re-linking from Clerk development IDs to Clerk production IDs.
  #
  # Matches strictly by local `user_id` + `old_clerk_id` / `external_id`.
  # Verifies the manifest's SHA-256 `manifest_digest`, requires live target
  # Clerk verification on `apply!`, guards against running while the API still
  # trusts the source dev issuer with email auto-provisioning active, never
  # writes in dry-run mode, and refuses to write unless `confirm: true`
  # (APPLY=true) is explicitly passed.
  class RelinkService
    class WriteRefusedError < StandardError; end
    class ValidationError < StandardError; end

    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/i

    Entry = Data.define(:user_id, :old_clerk_id, :new_clerk_id, :external_id, :old_clerk_invitation_id)

    Result = Data.define(
      :mode,
      :passed,
      :total_entries,
      :to_relink,
      :already_relinked,
      :relinked,
      :to_rollback,
      :already_rolled_back,
      :rolled_back,
      :errors
    ) do
      def passed?
        passed
      end

      def as_json(*)
        {
          mode: mode,
          passed: passed,
          total_entries: total_entries,
          to_relink: to_relink,
          already_relinked: already_relinked,
          relinked: relinked,
          to_rollback: to_rollback,
          already_rolled_back: already_rolled_back,
          rolled_back: rolled_back,
          errors_count: errors.length,
          errors: errors
        }
      end
    end

    def self.compute_manifest_digest(entries)
      canonical = Array(entries).map do |entry|
        row = entry.is_a?(Entry) ? entry.to_h.transform_keys(&:to_s) : entry.transform_keys(&:to_s)
        old_clerk_id = row["old_clerk_id"].to_s.strip
        {
          "user_id" => row["user_id"],
          "old_clerk_id" => old_clerk_id,
          "new_clerk_id" => row["new_clerk_id"].to_s.strip,
          "external_id" => row["external_id"].to_s.strip.presence || old_clerk_id,
          "old_clerk_invitation_id" => row["old_clerk_invitation_id"].presence
        }
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    def initialize(
      manifest:,
      user_scope: User,
      target_client: nil,
      allow_partial: false,
      env: ENV,
      source_issuer: nil,
      confirm_m3_1_deployed: false,
      operator: nil
    )
      @raw_manifest = manifest
      @user_scope = user_scope
      @target_client = target_client
      @allow_partial = allow_partial
      @env = env
      @source_issuer = source_issuer
      @confirm_m3_1_deployed = confirm_m3_1_deployed
      @operator = operator.presence || env["OPERATOR"].presence
    end

    def dry_run
      plan = build_apply_plan(require_target_client: false)
      Result.new(
        mode: "dry_run",
        passed: plan[:errors].empty?,
        total_entries: plan[:entries].length,
        to_relink: plan[:to_relink].length,
        already_relinked: plan[:already_relinked].length,
        relinked: 0,
        to_rollback: 0,
        already_rolled_back: 0,
        rolled_back: 0,
        errors: plan[:errors]
      )
    end

    def apply!(confirm: false)
      unless confirm == true
        raise WriteRefusedError, "Refusing to apply Clerk re-link without explicit confirm: true (APPLY=true)"
      end

      plan = build_apply_plan(require_target_client: true, enforce_sequencing_guard: true)
      if plan[:errors].any?
        return failed_apply_result(plan, plan[:errors])
      end

      relinked_count = 0
      begin
        @user_scope.transaction do
          plan[:to_relink].each do |item|
            user = @user_scope.lock.find(item[:entry].user_id)
            next if user.clerk_id == item[:entry].new_clerk_id

            unless user.clerk_id == item[:entry].old_clerk_id
              raise ValidationError, "user_id=#{user.id}: clerk_id changed concurrently before apply"
            end

            cleared_session = user.last_session_id_digest.present?
            cleared_invitation = user.clerk_invitation_id.present?

            user.update!(
              clerk_id: item[:entry].new_clerk_id,
              last_session_id_digest: nil,
              clerk_invitation_id: nil
            )

            AuditLog.record!(
              user: nil,
              organization_id: user.organization_id,
              company_id: user.company_id,
              action: "users#clerk_production_relinked",
              record_type: "User",
              record_id: user.id,
              subject_name: "User ##{user.id}",
              metadata: {
                matching_strategy: "external_id",
                operator: @operator,
                old_clerk_id: item[:entry].old_clerk_id,
                new_clerk_id: item[:entry].new_clerk_id,
                cleared_session: cleared_session,
                cleared_invitation: cleared_invitation
              }.compact,
              event_category: "security"
            )

            relinked_count += 1
          end
        end
      rescue ValidationError => e
        return failed_apply_result(plan, [ e.message ])
      end

      Result.new(
        mode: "apply",
        passed: true,
        total_entries: plan[:entries].length,
        to_relink: plan[:to_relink].length,
        already_relinked: plan[:already_relinked].length,
        relinked: relinked_count,
        to_rollback: 0,
        already_rolled_back: 0,
        rolled_back: 0,
        errors: []
      )
    end

    def rollback!(confirm: false)
      unless confirm == true
        raise WriteRefusedError, "Refusing to roll back Clerk re-link without explicit confirm: true (APPLY=true)"
      end

      plan = build_rollback_plan
      if plan[:errors].any?
        return failed_rollback_result(plan, plan[:errors])
      end

      rolled_back_count = 0
      begin
        @user_scope.transaction do
          plan[:to_rollback].each do |item|
            user = @user_scope.lock.find(item[:entry].user_id)
            next if user.clerk_id == item[:entry].old_clerk_id

            unless user.clerk_id == item[:entry].new_clerk_id
              raise ValidationError, "user_id=#{user.id}: clerk_id changed concurrently before rollback"
            end

            cleared_session = user.last_session_id_digest.present?
            restored_invitation = item[:entry].old_clerk_invitation_id.present?
            user.update!(
              clerk_id: item[:entry].old_clerk_id,
              clerk_invitation_id: item[:entry].old_clerk_invitation_id,
              last_session_id_digest: nil
            )

            AuditLog.record!(
              user: nil,
              organization_id: user.organization_id,
              company_id: user.company_id,
              action: "users#clerk_production_relink_rolled_back",
              record_type: "User",
              record_id: user.id,
              subject_name: "User ##{user.id}",
              metadata: {
                matching_strategy: "external_id",
                operator: @operator,
                restored_clerk_id: item[:entry].old_clerk_id,
                reverted_clerk_id: item[:entry].new_clerk_id,
                cleared_session: cleared_session,
                restored_invitation: restored_invitation
              }.compact,
              event_category: "security"
            )

            rolled_back_count += 1
          end
        end
      rescue ValidationError => e
        return failed_rollback_result(plan, [ e.message ])
      end

      Result.new(
        mode: "rollback",
        passed: true,
        total_entries: plan[:entries].length,
        to_relink: 0,
        already_relinked: 0,
        relinked: 0,
        to_rollback: plan[:to_rollback].length,
        already_rolled_back: plan[:already_rolled_back].length,
        rolled_back: rolled_back_count,
        errors: []
      )
    end

    private

    def failed_apply_result(plan, errors)
      Result.new(
        mode: "apply",
        passed: false,
        total_entries: plan[:entries].length,
        to_relink: plan[:to_relink].length,
        already_relinked: plan[:already_relinked].length,
        relinked: 0,
        to_rollback: 0,
        already_rolled_back: 0,
        rolled_back: 0,
        errors: errors
      )
    end

    def failed_rollback_result(plan, errors)
      Result.new(
        mode: "rollback",
        passed: false,
        total_entries: plan[:entries].length,
        to_relink: 0,
        already_relinked: 0,
        relinked: 0,
        to_rollback: plan[:to_rollback].length,
        already_rolled_back: plan[:already_rolled_back].length,
        rolled_back: 0,
        errors: errors
      )
    end

    def parse_manifest
      parsed = @raw_manifest.is_a?(String) ? JSON.parse(@raw_manifest) : @raw_manifest
      unless parsed.is_a?(Hash)
        return [ [], [ "Manifest must be a JSON object containing 'manifest_digest' and 'entries'" ] ]
      end

      raw_entries = parsed["entries"]
      return [ [], [ "Manifest must contain a non-empty 'entries' array" ] ] unless raw_entries.is_a?(Array) && raw_entries.any?

      entries = []
      errors = []
      seen_user_ids = Set.new
      seen_old_ids = Set.new
      seen_new_ids = Set.new

      raw_entries.each_with_index do |raw, index|
        unless raw.is_a?(Hash)
          errors << "entry #{index}: must be an object"
          next
        end

        row = raw.transform_keys(&:to_s)
        user_id = row["user_id"]
        old_clerk_id = row["old_clerk_id"].to_s.strip
        new_clerk_id = row["new_clerk_id"].to_s.strip
        external_id = row["external_id"].to_s.strip
        old_clerk_invitation_id = row["old_clerk_invitation_id"].presence

        unless user_id.is_a?(Integer) && user_id.positive?
          errors << "entry #{index}: user_id must be a positive integer"
          next
        end

        errors << "user_id=#{user_id}: duplicate user_id in manifest" unless seen_user_ids.add?(user_id)

        if old_clerk_id.empty? || old_clerk_id.start_with?("pending_")
          errors << "user_id=#{user_id}: old_clerk_id must be a non-pending Clerk user ID"
        elsif !seen_old_ids.add?(old_clerk_id)
          errors << "user_id=#{user_id}: duplicate old_clerk_id #{old_clerk_id}"
        end

        if new_clerk_id.empty? || new_clerk_id.start_with?("pending_")
          errors << "user_id=#{user_id}: new_clerk_id must be a non-pending Clerk user ID"
        elsif !seen_new_ids.add?(new_clerk_id)
          errors << "user_id=#{user_id}: duplicate new_clerk_id #{new_clerk_id}"
        end

        if old_clerk_id.present? && new_clerk_id.present? && old_clerk_id == new_clerk_id
          errors << "user_id=#{user_id}: new_clerk_id must differ from old_clerk_id"
        end

        if external_id.present? && external_id != old_clerk_id
          errors << "user_id=#{user_id}: external_id (#{external_id}) must equal old_clerk_id (#{old_clerk_id})"
        end

        entries << Entry.new(
          user_id: user_id,
          old_clerk_id: old_clerk_id,
          new_clerk_id: new_clerk_id,
          external_id: external_id.presence || old_clerk_id,
          old_clerk_invitation_id: old_clerk_invitation_id
        )
      end

      provided_digest = parsed["manifest_digest"].to_s.strip.downcase
      if provided_digest.empty? || !provided_digest.match?(DIGEST_PATTERN)
        errors << "Manifest is unsealed: missing or invalid SHA-256 manifest_digest"
      elsif errors.empty?
        expected_digest = self.class.compute_manifest_digest(entries)
        unless ActiveSupport::SecurityUtils.secure_compare(provided_digest, expected_digest)
          errors << "Manifest digest mismatch (manifest appears tampered or unsealed)"
        end
      end

      [ entries, errors ]
    rescue JSON::ParserError => e
      [ [], [ "Invalid manifest JSON: #{e.message}" ] ]
    end

    def build_apply_plan(require_target_client:, enforce_sequencing_guard: false)
      entries, errors = parse_manifest

      if enforce_sequencing_guard
        guard_error = sequencing_guard_error
        errors << guard_error if guard_error
      end

      if require_target_client && @target_client.nil?
        errors << "Target Clerk client (TARGET_CLERK_SECRET_KEY) is required for apply to verify every new_clerk_id external_id"
      end

      return { entries: entries, to_relink: [], already_relinked: [], errors: errors } if errors.any?

      users_by_id = @user_scope.where(id: entries.map(&:user_id)).index_by(&:id)
      existing_by_new_id = @user_scope.where(clerk_id: entries.map(&:new_clerk_id)).index_by(&:clerk_id)
      target_by_id = load_target_users_by_id(errors)

      to_relink = []
      already_relinked = []

      entries.each do |entry|
        user = users_by_id[entry.user_id]
        unless user
          errors << "user_id=#{entry.user_id}: local user not found"
          next
        end

        unless user.active?
          errors << "user_id=#{entry.user_id}: refusing to re-link inactive user"
          next
        end

        conflict_user = existing_by_new_id[entry.new_clerk_id]
        if conflict_user && conflict_user.id != user.id
          errors << "user_id=#{entry.user_id}: new_clerk_id #{entry.new_clerk_id} is already assigned to user_id=#{conflict_user.id}"
          next
        end

        if target_by_id
          target_user = target_by_id[entry.new_clerk_id]
          if target_user.nil?
            errors << "user_id=#{entry.user_id}: new_clerk_id #{entry.new_clerk_id} not found in target Clerk instance"
            next
          elsif target_user["external_id"].to_s.strip != entry.old_clerk_id
            errors << "user_id=#{entry.user_id}: target Clerk external_id mismatch for #{entry.new_clerk_id}"
            next
          end
        end

        if user.clerk_id == entry.old_clerk_id
          to_relink << { entry: entry, user: user }
        elsif user.clerk_id == entry.new_clerk_id
          already_relinked << { entry: entry, user: user }
        else
          errors << "user_id=#{entry.user_id}: local clerk_id mismatch (expected #{entry.old_clerk_id} or #{entry.new_clerk_id})"
        end
      end

      unless @allow_partial
        manifest_user_ids = entries.map(&:user_id).to_set
        unaccounted = @user_scope
          .where(active: true)
          .where.not(clerk_id: [ nil, "" ])
          .reject { |user| user.clerk_id.start_with?("pending_") || manifest_user_ids.include?(user.id) }

        if unaccounted.any?
          errors << "#{unaccounted.length} active bound local user(s) missing from manifest (user_ids: #{unaccounted.map(&:id).sort.join(', ')})"
        end
      end

      { entries: entries, to_relink: to_relink, already_relinked: already_relinked, errors: errors }
    end

    def build_rollback_plan
      entries, errors = parse_manifest
      return { entries: entries, to_rollback: [], already_rolled_back: [], errors: errors } if errors.any?

      users_by_id = @user_scope.where(id: entries.map(&:user_id)).index_by(&:id)
      existing_by_old_id = @user_scope.where(clerk_id: entries.map(&:old_clerk_id)).index_by(&:clerk_id)

      to_rollback = []
      already_rolled_back = []

      entries.each do |entry|
        user = users_by_id[entry.user_id]
        unless user
          errors << "user_id=#{entry.user_id}: local user not found"
          next
        end

        conflict_user = existing_by_old_id[entry.old_clerk_id]
        if conflict_user && conflict_user.id != user.id
          errors << "user_id=#{entry.user_id}: old_clerk_id #{entry.old_clerk_id} is currently assigned to user_id=#{conflict_user.id}"
          next
        end

        if user.clerk_id == entry.new_clerk_id
          to_rollback << { entry: entry, user: user }
        elsif user.clerk_id == entry.old_clerk_id
          already_rolled_back << { entry: entry, user: user }
        else
          errors << "user_id=#{entry.user_id}: local clerk_id does not match new_clerk_id or old_clerk_id"
        end
      end

      { entries: entries, to_rollback: to_rollback, already_rolled_back: already_rolled_back, errors: errors }
    end

    def sequencing_guard_error
      return nil if @confirm_m3_1_deployed == true

      configured_issuer = ClerkTokenVerifier.new(env: @env).clerk_issuer
      normalized_source = ClerkTokenVerifier.normalize_origin(@source_issuer || @env["SOURCE_CLERK_ISSUER"])

      if normalized_source.present? && configured_issuer == normalized_source
        return "Refusing to apply while configured Clerk issuer (#{configured_issuer}) equals source issuer; " \
               "switch issuer first or pass confirm_m3_1_deployed: true (CONFIRM_M3_1_DEPLOYED=true) once M3-1 is deployed"
      end

      if configured_issuer.present? && configured_issuer.end_with?(".clerk.accounts.dev")
        return "Refusing to apply while configured Clerk issuer (#{configured_issuer}) is a Clerk dev issuer; " \
               "email auto-provisioning could overwrite relinked clerk_ids. Switch issuer first or pass " \
               "confirm_m3_1_deployed: true (CONFIRM_M3_1_DEPLOYED=true) once M3-1 is deployed"
      end

      nil
    end

    def load_target_users_by_id(errors)
      return nil unless @target_client

      @target_client.list_users.index_by { |user| user["id"].to_s.strip }
    rescue ClerkClient::Error => e
      errors << "Failed to verify target Clerk users: #{e.message}"
      nil
    end
  end
end
