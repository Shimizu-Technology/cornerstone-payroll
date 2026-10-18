# frozen_string_literal: true

class HistoricalClientBootstrapDispatch < ApplicationRecord
  DISPATCH_LOCK_NAMESPACE = 714_292
  REDISPATCH_AFTER = 30.minutes
  MAX_DISPATCH_ATTEMPTS = 5
  MISSING_REQUESTER_ERROR = "The requesting payroll user is no longer available"
  RETRIES_EXHAUSTED_ERROR = "Employee preparation did not complete after #{MAX_DISPATCH_ATTEMPTS} dispatch attempts"

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
    scope.find_each do |dispatch|
      dispatch.dispatch!
    rescue QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized
      # Preserve pending evidence; a later authorized request can resume it.
      next
    end
  end

  def dispatch!(authorization_actor: nil)
    with_active_dispatch_lock do
      bootstrap = historical_client_bootstrap
      prepared = with_business_locks(bootstrap) do
        unless current_attempt?(bootstrap)
          update!(completed_at: Time.current, last_error: nil)
          next false
        end
        next false if enqueued_at.present? && enqueued_at >= REDISPATCH_AFTER.ago

        # Automatic recovery may retry already-dispatched work. A first dispatch,
        # including one recovered from a queue outage, still needs live authority.
        authorization_actor ||= requested_by if enqueued_at.nil?
        authorize_dispatch!(authorization_actor) if authorization_actor
        if dispatch_attempts >= MAX_DISPATCH_ATTEMPTS
          fail_attempt!(bootstrap, RETRIES_EXHAUSTED_ERROR)
          next false
        end
        unless requested_by
          self.dispatch_attempts += 1
          fail_attempt!(bootstrap, MISSING_REQUESTER_ERROR)
          next false
        end
        # The durable requester is the current executor; the original queue
        # audit remains attributed to the operator who initiated the attempt.
        if authorization_actor && requested_by_id != authorization_actor.id
          previous_requester_id = requested_by_id
          update!(requested_by: authorization_actor)
          AuditLog.record!(
            user: authorization_actor, organization_id: bootstrap.company.organization_id, company_id: bootstrap.company_id,
            action: "historical_imports#resume_client_bootstrap", record_type: "historical_client_bootstraps", record_id: bootstrap.id,
            metadata: { dispatch_id: id, attempt_token: attempt_token, previous_requester_id: previous_requester_id,
              requested_by_id: authorization_actor.id }
          )
        end
        true
      end
      next false unless prepared

      # All business row locks are released before this final, short check and
      # queue transport. The advisory lock only serializes this dispatch's senders.
      User.transaction { authorize_dispatch!(authorization_actor) } if authorization_actor
      submit_job!(bootstrap, authorization_actor)
    end
  rescue QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized
    raise
  rescue StandardError => e
    Rails.logger.error("Historical client bootstrap dispatch #{id} could not be enqueued: #{e.class}: #{e.message}")
    false
  end

  private

  def submit_job!(bootstrap, authorization_actor)
    QuickbooksHistory::ClientBootstrapJob.perform_later(bootstrap.id, authorization_actor&.id || requested_by_id, attempt_token)
    with_lock do
      # The worker can finish before the adapter returns. Preserve its terminal
      # evidence while recording that this submission was accepted.
      update!(dispatch_attempts: dispatch_attempts + 1, enqueued_at: Time.current, last_error: completed_at ? last_error : nil)
    end
    true
  rescue StandardError => e
    with_business_locks(bootstrap) do
      authorize_dispatch!(authorization_actor) if authorization_actor
      self.dispatch_attempts += 1
      if dispatch_attempts >= MAX_DISPATCH_ATTEMPTS
        fail_attempt!(bootstrap, RETRIES_EXHAUSTED_ERROR)
      else
        update!(last_error: e.message)
      end
    end
    Rails.logger.error("Historical client bootstrap dispatch #{id} could not be enqueued: #{e.class}: #{e.message}")
    false
  end

  def authorize_dispatch!(actor)
    QuickbooksHistory::ClientBootstrapAuthorization.ensure_authorized!(
      actor: actor, company_id: historical_client_bootstrap.company_id, lock: true
    )
  end

  def with_business_locks(bootstrap)
    bootstrap.with_lock do
      with_lock do
        bootstrap.reload
        yield
      end
    end
  end

  def with_active_dispatch_lock
    self.class.connection_pool.with_connection do |connection|
      binds = [ DISPATCH_LOCK_NAMESPACE, id ].map.with_index do |value, index|
        ActiveRecord::Relation::QueryAttribute.new("lock_key_#{index}", value, ActiveRecord::Type::Integer.new)
      end
      locked = connection.exec_query("SELECT pg_try_advisory_lock($1, $2)", "Client bootstrap dispatch lock", binds).rows.first.first
      return false unless ActiveModel::Type::Boolean.new.cast(locked)

      begin
        yield
      ensure
        connection.exec_query("SELECT pg_advisory_unlock($1, $2)", "Client bootstrap dispatch unlock", binds)
      end
    end
  end

  def current_attempt?(bootstrap)
    bootstrap.pending? && bootstrap.apply_started_at&.iso8601(6) == attempt_token
  end

  def fail_attempt!(bootstrap, message)
    bootstrap.with_lock do
      unless current_attempt?(bootstrap.reload)
        update!(completed_at: Time.current, last_error: nil)
        next false
      end

      bootstrap.update!(status: "failed", apply_error: message)
      update!(completed_at: Time.current, last_error: message)
      true
    end
  end

  def prevent_destroy
    errors.add(:base, "Client bootstrap dispatch evidence cannot be deleted")
    throw(:abort)
  end
end
