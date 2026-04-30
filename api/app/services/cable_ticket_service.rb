# frozen_string_literal: true

class CableTicketService
  TTL = 1.minute
  CACHE_PREFIX = "cable_ticket:"

  def self.issue!(user:, company_id:)
    ticket = SecureRandom.urlsafe_base64(32)
    Rails.cache.write(
      cache_key(ticket),
      {
        "user_id" => user.id,
        "company_id" => company_id
      },
      expires_in: TTL
    )
    ticket
  end

  def self.consume(ticket)
    return nil if ticket.blank?

    key = cache_key(ticket)
    payload = Rails.cache.read(key)
    Rails.cache.delete(key)
    payload
  end

  def self.cache_key(ticket)
    "#{CACHE_PREFIX}#{ticket}"
  end
end
