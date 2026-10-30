# frozen_string_literal: true

class AirePayrollCalendarSourceRefreshJob < ConnectedPayrollJob
  queue_as :default

  def perform(source_id)
    AirePayrollCalendar::SourceState.new(TimeTrackingSource.find(source_id)).refresh
  end
end
