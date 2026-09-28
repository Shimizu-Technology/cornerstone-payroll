# frozen_string_literal: true

class InvoiceRecurrenceDispatchJob < ApplicationJob
  queue_as :default

  def perform
    InvoiceRecurrenceGenerator.generate_due!
  end
end
