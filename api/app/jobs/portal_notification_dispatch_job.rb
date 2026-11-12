# frozen_string_literal: true

class PortalNotificationDispatchJob < ApplicationJob
  queue_as :default

  def perform
    PortalNotifications::Dispatcher.run!
  end
end
