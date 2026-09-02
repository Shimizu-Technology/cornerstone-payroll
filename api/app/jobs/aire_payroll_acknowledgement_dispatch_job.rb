# frozen_string_literal: true

class AirePayrollAcknowledgementDispatchJob < ApplicationJob
  queue_as :default

  def perform
    AirePayrollAcknowledgement.dispatch_pending!
  end
end
