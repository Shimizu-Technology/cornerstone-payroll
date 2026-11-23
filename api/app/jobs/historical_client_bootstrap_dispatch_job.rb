# frozen_string_literal: true

class HistoricalClientBootstrapDispatchJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform
    HistoricalClientBootstrapDispatch.dispatch_pending!
  end
end
