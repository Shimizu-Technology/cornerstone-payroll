# frozen_string_literal: true

# Sends a saved notice to an employee's previous email address after the
# address on file changed (EmployeeLinks::EmailChange), retrying transport
# failures with the same idempotency key. With no argument it is the
# recurring sweep for notices whose job was lost or is due a retry. Its only
# argument is the notice id, and its errors never name the address.
class SendEmployeeEmailChangeNoticeJob < ApplicationJob
  self.rls_mode = :system
  self.log_arguments = false

  queue_as :default
  retry_on EmployeeLinks::EmailChange::DeliveryError, wait: :polynomially_longer,
    attempts: EmployeeLinks::EmailChange::MAX_ATTEMPTS

  def perform(notice_id = nil)
    return EmployeeLinks::EmailChange.deliver_pending!(notice_id) if notice_id

    EmployeeLinks::EmailChange.retry_unsent!
  end
end
