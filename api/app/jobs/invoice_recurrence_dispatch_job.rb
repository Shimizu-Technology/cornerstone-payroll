# frozen_string_literal: true

class InvoiceRecurrenceDispatchJob < ApplicationJob
  self.rls_mode = :exempt_tables_only

  queue_as :default

  def perform
    InvoiceRecurrenceGenerator.generate_due!
  end
end
