# frozen_string_literal: true

class PortalNotificationDispatchJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform(company_id = nil)
    PortalNotifications::Dispatcher.run!(company_id: company_id)
  end
end
