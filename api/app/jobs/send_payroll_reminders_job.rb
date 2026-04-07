# frozen_string_literal: true

class SendPayrollRemindersJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform
    PayrollReminderService.run_all!
  end
end
