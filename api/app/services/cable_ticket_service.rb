# frozen_string_literal: true

class CableTicketService
  TTL = 1.minute

  def self.issue!(user:, company_id:)
    CableConnectionTicket.stale.delete_all

    ticket = SecureRandom.urlsafe_base64(32)

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

    {
      "user_id" => consumed_ticket.user_id,
      "company_id" => consumed_ticket.company_id
    }
  end

  def self.token_digest(ticket)
    OpenSSL::Digest::SHA256.hexdigest(ticket)
  end
end
