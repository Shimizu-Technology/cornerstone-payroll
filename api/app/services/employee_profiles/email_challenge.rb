# frozen_string_literal: true

module EmployeeProfiles
  # One outstanding challenge per link. Call inside the transaction that
  # locks the link and employee, so sends and confirmations can't race.
  class EmailChallenge
    LIFETIME = 10.minutes
    RESEND_DELAY = 1.minute
    MAX_ATTEMPTS = 5
    class DeliveryUnavailable < StandardError; end

    def initialize(link, employee)
      @link = link
      @employee = employee
    end

    def retry_after
      return 0 unless @link.profile_email_sent_at

      [ (@link.profile_email_sent_at + RESEND_DELAY - Time.current).ceil, 0 ].max
    end

    def issue!(email)
      id = SecureRandom.hex(16)
      code = format("%06d", SecureRandom.random_number(1_000_000))
      @link.update!(profile_email_sent_at: Time.current, profile_email_challenge: {
        "id" => id, "email" => email, "baseline" => baseline, "digest" => digest(id, code), "attempts" => 0
      }.to_json)
      deliver!(email, id, code)
      id
    end

    # A wrong attempt must commit, even though the controller responds 422.
    # Return the email only when the code is valid. The caller consumes it
    # in the same transaction that applies the verified address.
    def verify!(id, code)
      state = JSON.parse(@link.profile_email_challenge || "{}")
      return unless state["id"] == id && @link.profile_email_sent_at
      if Time.current >= @link.profile_email_sent_at + LIFETIME || state["baseline"] != baseline
        consume!
        return
      end

      if code.match?(/\A[0-9]{6}\z/) && ActiveSupport::SecurityUtils.secure_compare(state.fetch("digest"), digest(id, code))
        return state.fetch("email")
      end

      state["attempts"] += 1
      if state["attempts"] >= MAX_ATTEMPTS
        consume!
      else
        @link.update!(profile_email_challenge: state.to_json)
      end
      nil
    end

    def consume!
      @link.update!(profile_email_challenge: nil)
    end

    private

    def baseline
      # An intervening staff edit must not be overwritten by an older code.
      [ @link.user_id, @employee.email, @employee.email_verified_at&.iso8601(6) ]
    end

    def digest(id, code)
      key = Rails.application.key_generator.generate_key("employee_profiles/email_challenge", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, "#{@link.id}:#{id}:#{code}")
    end

    def deliver!(email, id, code)
      transport = PortalNotifications::Transport
      raise DeliveryUnavailable unless transport.configured?

      result = transport.deliver({
        from: transport.from_email, to: [ email ], subject: "Cornerstone Payroll email verification",
        text: "Your Cornerstone Payroll verification code is #{code}. It expires in 10 minutes. If you didn't request this code, you can ignore this email."
      }, idempotency_key: "employee-profile-email:#{id}")
      raise DeliveryUnavailable if result["id"].blank? || result["staging_captured"]
    rescue StandardError => error
      Rails.logger.warn("Employee email verification delivery unavailable: #{error.class}")
      raise DeliveryUnavailable
    end
  end
end
