# frozen_string_literal: true

class InvoiceSendDispatchJob < ApplicationJob
  queue_as :default

  def perform
    # A queue outage after a claim must not strand the schedule indefinitely.
    InvoiceSendSchedule.where(status: "queued").where("updated_at < ?", 10.minutes.ago)
                       .find_each do |schedule|
      next if queued_send_job_exists?(schedule.id)

      InvoiceSendSchedule.where(id: schedule.id, status: "queued")
                         .update_all(status: "pending", updated_at: Time.current)
    end

    # A worker can exit after claiming an email. Leave it for explicit review and
    # retry rather than automatically sending a second copy after a timeout.
    InvoiceSendSchedule.transaction do
      stale_ids = InvoiceSendSchedule.where(status: "sending").where("claimed_at < ?", 1.hour.ago)
                                     .order(:id).limit(100).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
                                     .select { |id| InvoiceSendSchedule.recovery_lock_available?(id) }
      InvoiceSendSchedule.where(id: stale_ids, status: "sending")
                         .update_all(status: "failed", last_error: "Sending was interrupted; verify provider delivery before retrying",
                                     updated_at: Time.current) if stale_ids.any?
    end

    ids = InvoiceSendSchedule.transaction do
      schedules = InvoiceSendSchedule.due.order(:send_at, :id).limit(100)
                                     .lock("FOR UPDATE SKIP LOCKED").to_a
      schedules.each { |schedule| schedule.update!(status: "queued") }
      schedules.map(&:id)
    end

    ids.each do |id|
      InvoiceSendJob.perform_later(id)
    rescue StandardError
      InvoiceSendSchedule.where(id: id, status: "queued").update_all(status: "pending", updated_at: Time.current)
      raise
    end
  end

  private

  def queued_send_job_exists?(schedule_id)
    SolidQueue::Job.where(class_name: "InvoiceSendJob", finished_at: nil)
                   .where.not(id: SolidQueue::FailedExecution.select(:job_id))
                   .where("arguments::jsonb -> 'arguments' @> ?::jsonb", [ schedule_id ].to_json)
                   .exists?
  end
end
