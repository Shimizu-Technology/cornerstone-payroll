# frozen_string_literal: true

class AireManualAllocationSyncJob < ApplicationJob
  queue_as :default

  retry_on TimeTracking::Client::Error, wait: :polynomially_longer, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  def perform(allocation_id)
    allocation = TimeTrackingManualAllocation.includes(:created_by, :time_tracking_source, :pay_period, :payroll_item).find(allocation_id)
    TimeTracking::ManualAllocationService.new(
      pay_period: allocation.pay_period,
      source: allocation.time_tracking_source,
      actor: allocation.created_by
    ).sync!(allocation, raise_on_failure: true)
  end
end
