# frozen_string_literal: true

require "uri"

module ClerkCutover
  # Strictly read-only preflight checks prior to Clerk production cutover.
  # Never writes to the database or mutates Clerk, and never matches users by email.
  class PreflightService
    DEV_USER_CAP = 100
    DEV_CAP_WARNING_THRESHOLD = 80

    Check = Data.define(:name, :passed, :detail, :metadata)

    class Report
      attr_reader :checks, :generated_at

      def initialize(checks:, generated_at: Time.current)
        @checks = checks
        @generated_at = generated_at
      end

      def passed?
        checks.all?(&:passed)
      end

      def failures
        checks.reject(&:passed)
      end

      def as_json(*)
        {
          generated_at: generated_at.iso8601,
          passed: passed?,
          checks: checks.map do |check|
            {
              name: check.name,
              passed: check.passed,
              detail: check.detail,
              metadata: check.metadata
            }
          end
        }
      end
    end

    def initialize(
      env: ENV,
      user_scope: User,
      source_client: nil,
      target_client: nil,
      target_issuer: nil
    )
      @env = env
      @user_scope = user_scope
      @source_client = source_client
      @target_client = target_client
      @target_issuer = target_issuer.presence || env["TARGET_CLERK_ISSUER"].presence
    end

    def run
      checks = []
      local_users = @user_scope.order(:id).to_a

      checks << check_local_users(local_users)
      checks << check_verifier_issuer
      checks << check_authorized_parties

      source_users, source_error = fetch_source_users
      checks << check_no_totp_enrolled(source_users, source_error)
      checks << check_source_user_cap(source_users, source_error)
      checks << check_source_clerk_id_reconciliation(local_users, source_users, source_error)

      checks << check_target_jwks if @target_issuer.present?
      checks << check_target_instance if target_client_available?

      Report.new(checks: checks)
    end

    private

    def check_local_users(local_users)
      active_users = local_users.select(&:active?)
      bound_active = active_users.reject { |user| pending_or_blank_clerk_id?(user.clerk_id) }
      pending_active = active_users.select(&:invitation_pending?)
      unbound_accepted_active = active_users.select do |user|
        !user.invitation_pending? && pending_or_blank_clerk_id?(user.clerk_id)
      end

      duplicate_clerk_ids = local_users
        .map(&:clerk_id)
        .reject(&:blank?)
        .tally
        .select { |_clerk_id, count| count > 1 }
        .keys

      passed = duplicate_clerk_ids.empty? && unbound_accepted_active.empty?
      detail = if passed
        "#{local_users.length} local user(s) inspected (#{bound_active.length} active bound, #{pending_active.length} pending)"
      else
        reasons = []
        reasons << "#{duplicate_clerk_ids.length} duplicate clerk_id(s)" if duplicate_clerk_ids.any?
        reasons << "#{unbound_accepted_active.length} active accepted user(s) without a bound clerk_id" if unbound_accepted_active.any?
        reasons.join("; ")
      end

      Check.new(
        name: "local users are ready for cutover inventory",
        passed: passed,
        detail: detail,
        metadata: {
          total_users: local_users.length,
          active_users: active_users.length,
          inactive_users: local_users.length - active_users.length,
          bound_active_users: bound_active.length,
          pending_active_users: pending_active.length,
          unbound_accepted_active_user_ids: unbound_accepted_active.map(&:id),
          duplicate_clerk_id_count: duplicate_clerk_ids.length
        }
      )
    end

    def check_verifier_issuer
      verifier = ClerkTokenVerifier.new(env: @env)
      issuer = verifier.clerk_issuer
      passed = issuer.present? && valid_https_origin?(issuer)

      Check.new(
        name: "ClerkTokenVerifier resolves a valid HTTPS issuer",
        passed: passed,
        detail: passed ? "resolved #{issuer}" : "unable to resolve a valid HTTPS Clerk issuer",
        metadata: { issuer: issuer }
      )
    end

    def check_authorized_parties
      verifier = ClerkTokenVerifier.new(env: @env)
      parties = verifier.authorized_parties
      passed = parties.present? && parties.all? { |origin| valid_https_origin?(origin) }

      Check.new(
        name: "CLERK_AUTHORIZED_PARTIES is configured with explicit HTTPS origins",
        passed: passed,
        detail: passed ? "#{parties.length} HTTPS origin(s) configured" : "CLERK_AUTHORIZED_PARTIES is unset or contains invalid origins",
        metadata: { count: parties.length }
      )
    end

    def fetch_source_users
      client = effective_source_client
      return [ nil, "SOURCE_CLERK_SECRET_KEY / CLERK_SECRET_KEY is not configured" ] unless client

      [ client.list_users, nil ]
    rescue ClerkClient::Error => e
      [ nil, e.message ]
    end

    def check_no_totp_enrolled(source_users, source_error)
      if source_error
        return Check.new(
          name: "no Clerk user has TOTP enrolled",
          passed: false,
          detail: source_error,
          metadata: {}
        )
      end

      totp_users = source_users.select { |user| totp_enrolled?(user) }
      passed = totp_users.empty?
      detail = if passed
        "0 of #{source_users.length} Clerk user(s) have TOTP enrolled"
      else
        "#{totp_users.length} Clerk user(s) have TOTP enrolled; audit or reset before cutover"
      end

      Check.new(
        name: "no Clerk user has TOTP enrolled",
        passed: passed,
        detail: detail,
        metadata: {
          source_clerk_user_count: source_users.length,
          totp_enrolled_count: totp_users.length,
          totp_enrolled_clerk_ids: totp_users.map { |user| user["id"] }.compact
        }
      )
    end

    def check_source_user_cap(source_users, source_error)
      if source_error
        return Check.new(
          name: "source Clerk user count is within development cap",
          passed: false,
          detail: source_error,
          metadata: {}
        )
      end

      count = source_users.length
      passed = count < DEV_USER_CAP
      detail = "#{count} of #{DEV_USER_CAP} Clerk dev user slots used"

      Check.new(
        name: "source Clerk user count is within development cap",
        passed: passed,
        detail: detail,
        metadata: {
          source_clerk_user_count: count,
          dev_cap: DEV_USER_CAP,
          approaching_cap: count >= DEV_CAP_WARNING_THRESHOLD
        }
      )
    end

    def check_source_clerk_id_reconciliation(local_users, source_users, source_error)
      if source_error
        return Check.new(
          name: "every active bound local clerk_id exists in source Clerk",
          passed: false,
          detail: source_error,
          metadata: {}
        )
      end

      source_ids = source_users.map { |user| user["id"] }.compact.to_set
      bound_active = local_users.select { |user| user.active? && !pending_or_blank_clerk_id?(user.clerk_id) }
      orphaned = bound_active.reject { |user| source_ids.include?(user.clerk_id) }
      passed = orphaned.empty?

      detail = if passed
        "all #{bound_active.length} active bound local user(s) matched source Clerk by clerk_id"
      else
        "#{orphaned.length} active bound local user(s) not found in source Clerk by clerk_id"
      end

      Check.new(
        name: "every active bound local clerk_id exists in source Clerk",
        passed: passed,
        detail: detail,
        metadata: {
          checked_count: bound_active.length,
          orphaned_user_ids: orphaned.map(&:id),
          orphaned_clerk_ids: orphaned.map(&:clerk_id)
        }
      )
    end

    def check_target_jwks
      client = effective_target_client || ClerkClient.new
      keys = client.fetch_jwks(@target_issuer)
      passed = keys.is_a?(Array) && keys.any?

      Check.new(
        name: "target Clerk JWKS endpoint serves signing keys",
        passed: passed,
        detail: passed ? "#{keys.length} signing key(s) returned from #{@target_issuer}" : "target JWKS returned no signing keys",
        metadata: { issuer: @target_issuer, key_count: Array(keys).length }
      )
    rescue ClerkClient::Error => e
      Check.new(
        name: "target Clerk JWKS endpoint serves signing keys",
        passed: false,
        detail: e.message,
        metadata: { issuer: @target_issuer }
      )
    end

    def check_target_instance
      instance = effective_target_client.fetch_instance
      instance_id = instance["id"].to_s.strip
      passed = instance_id.present?

      Check.new(
        name: "target Clerk Backend API accepts the configured key",
        passed: passed,
        detail: passed ? "authenticated target instance #{instance_id}" : "target instance response missing id",
        metadata: { instance_id: instance_id.presence }
      )
    rescue ClerkClient::Error => e
      Check.new(
        name: "target Clerk Backend API accepts the configured key",
        passed: false,
        detail: e.message,
        metadata: {}
      )
    end

    def effective_source_client
      return @source_client if @source_client

      secret = @env["SOURCE_CLERK_SECRET_KEY"].presence || @env["CLERK_SECRET_KEY"].presence
      return nil if secret.blank?

      ClerkClient.new(secret_key: secret)
    end

    def target_client_available?
      @target_client.present? || @env["TARGET_CLERK_SECRET_KEY"].present?
    end

    def effective_target_client
      return @target_client if @target_client

      secret = @env["TARGET_CLERK_SECRET_KEY"].presence
      return nil if secret.blank?

      ClerkClient.new(secret_key: secret)
    end

    def totp_enrolled?(clerk_user)
      clerk_user["totp_enabled"] == true ||
        clerk_user["two_factor_enabled"] == true ||
        clerk_user["backup_code_enabled"] == true
    end

    def pending_or_blank_clerk_id?(clerk_id)
      clerk_id.blank? || clerk_id.to_s.start_with?("pending_")
    end

    def valid_https_origin?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) &&
        uri.host.present? &&
        uri.port == 443 &&
        uri.userinfo.blank? &&
        [ "", "/" ].include?(uri.path) &&
        uri.query.blank? &&
        uri.fragment.blank?
    rescue URI::InvalidURIError
      false
    end
  end
end
