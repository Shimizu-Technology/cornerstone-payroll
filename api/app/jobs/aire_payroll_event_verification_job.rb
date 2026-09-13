# frozen_string_literal: true

class AirePayrollEventVerificationJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(event_id)
    AirePayrollEvents::Verifier.new(event_id: event_id).call
  end
end
