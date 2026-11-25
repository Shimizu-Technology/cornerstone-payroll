# frozen_string_literal: true

require "timeout"

module EmployeeProfiles
  # Issuance and verification run while the caller owns the link lock.
  # Delivery runs after the issuance transaction commits.
  class EmailChallenge
    LIFETIME = 10.minutes
    RESEND_DELAY = 1.minute
    MAX_ATTEMPTS = 5
    DAILY_CODE_LIMIT = 5
    DAILY_FAILURE_LIMIT = 15
    DELIVERY_TIMEOUT = 10.seconds
    Delivery = Data.define(:id, :email, :code)

    class DeliveryUnavailable < StandardError; end

    def initialize(link, employee)
      @link = link
      @employee = employee
    end

    def retry_after
      return 0 unless @link.profile_email_sent_at

      [ (@link.profile_email_sent_at + RESEND_DELAY - Time.current).ceil, 0 ].max
    end

    def issuance_limit_reached?
      failure_limit_reached? || daily_count(:profile_email_daily_codes) >= DAILY_CODE_LIMIT
    end

    def failure_limit_reached?
      daily_count(:profile_email_daily_failures) >= DAILY_FAILURE_LIMIT
    end

    def issue!(email)
      id = SecureRandom.hex(16)
      code = format("%06d", SecureRandom.random_number(1_000_000))
      track_usage(codes: 1)
      @link.update!(profile_email_sent_at: Time.current, profile_email_challenge: {
        "id" => id, "email" => email, "baseline" => baseline, "digest" => digest(id, code), "attempts" => 0
      }.to_json)
      Delivery.new(id, email, code)
    end

    def deliver!(delivery)
      transport = PortalNotifications::Transport
      raise DeliveryUnavailable unless transport.configured?

      result = Timeout.timeout(DELIVERY_TIMEOUT, Timeout::Error) do
        transport.deliver({
          from: transport.from_email, to: [ delivery.email ], subject: "Cornerstone Payroll email verification",
          text: "Your Cornerstone Payroll verification code is #{delivery.code}. It expires in 10 minutes. If you didn't request this code, you can ignore this email."
        }, idempotency_key: "employee-profile-email:#{delivery.id}")
      end
      raise DeliveryUnavailable if result["id"].blank? || result["staging_captured"]
    rescue StandardError => error
      Rails.logger.warn("Employee email verification delivery unavailable: #{error.class}")
      raise DeliveryUnavailable
    end

    def clear_failed_delivery!(id)
      @link.with_lock do
        consume! if challenge_state["id"] == id
      end
    end

    # A wrong attempt must commit, even though the controller responds 422 or 429.
    # The caller consumes a correct code in the transaction applying the email.
    def verify!(id, code)
      state = challenge_state
      if state["id"] == id && @link.profile_email_sent_at
        if Time.current >= @link.profile_email_sent_at + LIFETIME || state["baseline"] != baseline
          @link.profile_email_challenge = nil
        elsif code.match?(/\A[0-9]{6}\z/) && ActiveSupport::SecurityUtils.secure_compare(state.fetch("digest"), digest(id, code))
          return state.fetch("email")
        else
          state["attempts"] += 1
          @link.profile_email_challenge = state["attempts"] >= MAX_ATTEMPTS ? nil : state.to_json
        end
      end

      track_usage(failures: 1)
      @link.save!
      nil
    end

    def consume!
      @link.update!(profile_email_challenge: nil)
    end

    private

    def challenge_state
      JSON.parse(@link.profile_email_challenge || "{}")
    end

    def usage_date
      @usage_date ||= PayrollBusinessClock.today
    end

    def daily_count(attribute)
      @link.profile_email_usage_date == usage_date ? @link.public_send(attribute) : 0
    end

    def track_usage(codes: 0, failures: 0)
      @link.assign_attributes(
        profile_email_usage_date: usage_date,
        profile_email_daily_codes: daily_count(:profile_email_daily_codes) + codes,
        profile_email_daily_failures: daily_count(:profile_email_daily_failures) + failures
      )
    end

    def baseline
      # An intervening staff edit must not be overwritten by an older code.
      [ @link.user_id, @employee.email, @employee.email_verified_at&.iso8601(6) ]
    end

    def digest(id, code)
      key = Rails.application.key_generator.generate_key("employee_profiles/email_challenge", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, "#{@link.id}:#{id}:#{code}")
    end
  end
end
