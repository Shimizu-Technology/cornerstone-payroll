# frozen_string_literal: true

# Sends the short notice to an employee's previous email address after the
# address on file changed (EmployeeLinks::EmailChange). The address is a job
# argument, so arguments are kept out of the logs.
class SendEmployeeEmailChangeNoticeJob < ApplicationJob
  self.rls_mode = :system
  self.log_arguments = false

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(employee_id, to, changed_at)
    EmployeeLinks::EmailChange.deliver!(employee_id: employee_id, to: to, changed_at: changed_at)
  end
end
