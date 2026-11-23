# frozen_string_literal: true

class CableTicketService
  TTL = 1.minute
  MFA_VERIFIED_PREFIX = "mfa."

  def self.issue!(user:, company_id:, clerk_token_payload: nil, request_id: nil)
    verified = MfaPolicy.enabled? && MfaPolicy.verified_second_factor?(clerk_token_payload)
    if MfaPolicy.required_for?(user: user) && !verified
      MfaPolicy.record_denial!(user: user, source: "cable_ticket", request_id: request_id)
      raise MfaPolicy::VerificationRequired
    end

    CableConnectionTicket.stale.delete_all

    ticket = SecureRandom.urlsafe_base64(32)
    # The digest binds this server-issued marker to the random ticket.
    ticket = MFA_VERIFIED_PREFIX + ticket if verified

    CableConnectionTicket.create!(
      user: user,
      company_id: company_id,
      token_digest: token_digest(ticket),
      expires_at: TTL.from_now
    )

    ticket
  end

  def self.consume(ticket)
    return nil if ticket.blank?

    consumed_ticket = nil

    CableConnectionTicket.transaction do
      consumed_ticket = CableConnectionTicket.lock.active.find_by(token_digest: token_digest(ticket))
      consumed_ticket&.update!(used_at: Time.current)
    end

    return nil unless consumed_ticket

    payload = {
      "user_id" => consumed_ticket.user_id,
      "company_id" => consumed_ticket.company_id
    }
    payload["mfa_verified"] = true if ticket.start_with?(MFA_VERIFIED_PREFIX)
    payload
  end

  def self.token_digest(ticket)
    OpenSSL::Digest::SHA256.hexdigest(ticket)
  end
end
