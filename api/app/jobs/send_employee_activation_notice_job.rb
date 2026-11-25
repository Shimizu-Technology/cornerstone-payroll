# frozen_string_literal: true

# Delivers persisted employee-link activation security notices after the
# activation transaction commits, retrying transient failures with the same
# idempotency key and DemoOutbound checks. Called with no arguments by the
# recurring recovery sweep to pick up any pending/failed notices.
class SendEmployeeActivationNoticeJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default
  retry_on EmployeeLinks::ActivationNoticeEmail::DeliveryError,
    wait: :polynomially_longer,
    attempts: EmployeeLinks::ActivationNoticeEmail::MAX_ATTEMPTS

  def perform(link_id = nil)
    return EmployeeLinks::ActivationNoticeEmail.deliver_pending!(link_id) if link_id

    EmployeeLinks::ActivationNoticeEmail.retry_unsent!
  end
end
