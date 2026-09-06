# frozen_string_literal: true

class HistoricalClientBootstrapDispatchJob < ApplicationJob
  queue_as :default

  def perform
    HistoricalClientBootstrapDispatch.dispatch_pending!
  end
end
