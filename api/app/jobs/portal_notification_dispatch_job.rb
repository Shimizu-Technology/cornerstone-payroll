# frozen_string_literal: true

class PortalNotificationDispatchJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform
    PortalNotifications::Dispatcher.run!
  end
end
