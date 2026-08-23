# frozen_string_literal: true

module PayrollAccess
  class RevocationDispatcher
    class << self
      def call(user)
        job = RevokePayrollAccessJob.perform_later(user.id)
        return job if job

        disconnect_immediately(user, "revocation job enqueue was halted")
      rescue StandardError => e
        disconnect_immediately(user, "revocation job enqueue failed: #{e.class}: #{e.message}")
      end

      private

      def disconnect_immediately(user, enqueue_failure)
        Rails.logger.error("[RevocationDispatcher] #{enqueue_failure}; attempting immediate disconnect for user=#{user.id}")
        PayrollAccess::SessionRevoker.disconnect_user(user)
      rescue StandardError => e
        # Broadcast delivery still rechecks local access. Do not abort an
        # organization-wide loop and strand every user after this one.
        Rails.logger.error(
          "[RevocationDispatcher] Immediate disconnect failed for user=#{user.id}: #{e.class}: #{e.message}"
        )
        false
      end
    end
  end
end
