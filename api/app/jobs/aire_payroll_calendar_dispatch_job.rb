# frozen_string_literal: true

class AirePayrollCalendarDispatchJob < ApplicationJob
  queue_as :default

  def perform
    AirePayrollCalendarPublication.dispatch_due!
    AirePayrollEvent.dispatch_due!
  end
end
