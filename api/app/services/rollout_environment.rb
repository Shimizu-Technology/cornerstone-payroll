# frozen_string_literal: true

# Process settings shared by production readiness and the employee app
# switch (M4-9d). Each process evaluates its own environment.
module RolloutEnvironment
  module_function

  # REQUIRE_MFA=true plus the instance-bound evidence that the Clerk session
  # token carries the two_factor_enabled claim (M4-1).
  def mfa_evidence_recorded?(env = ENV)
    raw_instance_id = env["CLERK_MFA_ATTESTED_INSTANCE_ID"].to_s
    raw_evidence_ref = env["CLERK_MFA_EVIDENCE_REF"].to_s
    return false if raw_instance_id.match?(/[\r\n]/) || raw_evidence_ref.match?(/[\r\n]/)

    instance_id = raw_instance_id.strip
    evidence_ref = raw_evidence_ref.strip

    MfaPolicy.enabled?(env: env) &&
      instance_id.match?(/\Ains_[A-Za-z0-9]+\z/) &&
      evidence_ref.present? &&
      evidence_ref.bytesize <= 500
  end

  def clerk_authorized_parties_valid?(env = ENV)
    parties = env.fetch("CLERK_AUTHORIZED_PARTIES", "").split(",").map(&:strip).reject(&:empty?)
    parties.present? && parties.all? { |party| ClerkTokenVerifier.valid_production_https_origin?(party, env: env) }
  end
end
