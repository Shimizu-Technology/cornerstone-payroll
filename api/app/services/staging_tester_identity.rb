# frozen_string_literal: true

class StagingTesterIdentity
  def self.verify!(env: ENV)
    records = StagingOutboundPolicy.tester_records(env)
    records.each do |tester|
      user = User.unscoped.find_by(id: tester.fetch("user_id"))
      unless user && user.email.to_s.downcase == tester.fetch("email") && User.unscoped.where("lower(email) = ?", tester.fetch("email")).count == 1
        raise StagingOutboundPolicy::ConfigurationError, "STAGING_TESTER_BINDINGS must identify one exact local user ID and email"
      end
      if User.unscoped.where(clerk_id: tester.fetch("clerk_subject")).where.not(id: user.id).exists?
        raise StagingOutboundPolicy::ConfigurationError, "Staging Clerk subject belongs to another local user"
      end
    end
    # Verify every provider identity before the caller can make any writes.
    records.each do |tester|
      subject = tester.fetch("clerk_subject")
      key = StagingOutboundPolicy.require_setting!("CLERK_SECRET_KEY", env)
      raise StagingOutboundPolicy::ConfigurationError, "Staging requires CLERK_SECRET_KEY (sk_test_)" unless key.start_with?("sk_test_")
      response = HTTParty.get("https://api.clerk.com/v1/users/#{subject}", headers: { "Authorization" => "Bearer #{key}" }, timeout: 5)
      data = response.success? ? response.parsed_response : nil
      data = nil unless data.is_a?(Hash)
      primary = Array(data&.fetch("email_addresses", nil)).find { |address| address["id"] == data["primary_email_address_id"] }
      valid = data && data["id"] == subject && primary&.dig("verification", "status") == "verified" && primary["email_address"].to_s.downcase == tester.fetch("email")
      raise StagingOutboundPolicy::ConfigurationError, "Staging Clerk verified primary email does not match the named tester" unless valid
    end
    records
  rescue HTTParty::Error, Timeout::Error, SocketError, JSON::ParserError
    raise StagingOutboundPolicy::ConfigurationError, "Staging Clerk tester verification failed"
  end
end
