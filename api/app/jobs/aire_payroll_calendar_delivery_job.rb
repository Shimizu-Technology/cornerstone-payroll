# frozen_string_literal: true

class AirePayrollCalendarDeliveryJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(publication_id)
    AirePayrollCalendar::Delivery.new(publication_id: publication_id).call
  end
end
