# frozen_string_literal: true

class HistoricalClientBootstrapDispatch < ApplicationRecord
  REDISPATCH_AFTER = 30.minutes
  MISSING_REQUESTER_ERROR = "The requesting payroll user is no longer available"

  belongs_to :historical_client_bootstrap
  belongs_to :requested_by, class_name: "User", optional: true

  validates :attempt_token, presence: true, uniqueness: { scope: :historical_client_bootstrap_id }
  validates :dispatch_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  before_destroy :prevent_destroy

  scope :due_for_dispatch, lambda {
    joins(:historical_client_bootstrap)
      .where(completed_at: nil, historical_client_bootstraps: { status: "pending" })
      .where("historical_client_bootstrap_dispatches.enqueued_at IS NULL OR historical_client_bootstrap_dispatches.enqueued_at < ?", REDISPATCH_AFTER.ago)
  }

  def self.dispatch_pending!(ids: nil)
    scope = due_for_dispatch
    scope = scope.where(id: ids) if ids.present?
    scope.find_each(&:dispatch!)
  end

  def dispatch!
    with_lock do
      bootstrap = historical_client_bootstrap.reload
      unless current_attempt?(bootstrap)
        update!(completed_at: Time.current, last_error: nil)
        next false
      end
      next false if enqueued_at.present? && enqueued_at >= REDISPATCH_AFTER.ago

      self.dispatch_attempts += 1
      save!
      unless requested_by
        bootstrap.update!(status: "failed", apply_error: MISSING_REQUESTER_ERROR)
        update!(
          completed_at: Time.current,
          last_error: MISSING_REQUESTER_ERROR
        )
        next false
      end

      begin
        QuickbooksHistory::ClientBootstrapJob.perform_later(bootstrap.id, requested_by_id, attempt_token)
        update!(enqueued_at: Time.current, last_error: nil)
        true
      rescue StandardError => e
        update!(last_error: e.message)
        Rails.logger.error("Historical client bootstrap dispatch #{id} could not be enqueued: #{e.class}: #{e.message}")
        false
      end
    end
  rescue StandardError => e
    self.class.where(id: id).update_all(last_error: e.message, updated_at: Time.current) if persisted?
    Rails.logger.error("Historical client bootstrap dispatch #{id} could not be enqueued: #{e.class}: #{e.message}")
    false
  end

  private

  def current_attempt?(bootstrap)
    bootstrap.pending? && bootstrap.apply_started_at&.iso8601(6) == attempt_token
  end

  def prevent_destroy
    errors.add(:base, "Client bootstrap dispatch evidence cannot be deleted")
    throw(:abort)
  end
end
