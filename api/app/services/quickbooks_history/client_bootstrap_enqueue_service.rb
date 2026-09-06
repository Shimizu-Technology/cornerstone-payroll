# frozen_string_literal: true

module QuickbooksHistory
  class ClientBootstrapEnqueueService
    Result = Struct.new(:bootstrap, :enqueued, keyword_init: true)

    def initialize(bootstrap:, actor:, acknowledgement:)
      @bootstrap = bootstrap
      @actor = actor
      @acknowledgement = acknowledgement
    end

    def call
      ensure_authorized!
      raise ArgumentError, "Type #{ClientBootstrapApplyService::ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ClientBootstrapApplyService::ACKNOWLEDGEMENT

      prepared, should_enqueue = prepare_pending_bootstrap!
      return Result.new(bootstrap: prepared, enqueued: false) unless should_enqueue

      enqueue!(prepared)
      Result.new(bootstrap: prepared, enqueued: true)
    end

    private

    attr_reader :bootstrap, :actor, :acknowledgement

    def ensure_authorized!
      ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: bootstrap.company_id)
    end

    def prepare_pending_bootstrap!
      bootstrap.with_lock do
        bootstrap.reload
        return [ bootstrap, false ] if bootstrap.applied?
        if bootstrap.pending? && !bootstrap.stale_pending?
          return [ bootstrap, false ]
        end

        plan = ClientBootstrapPlan.new(batch: bootstrap.historical_import_batch).call
        raise ArgumentError, plan.errors.join("; ") unless plan.ready?
        unless ActiveSupport::SecurityUtils.secure_compare(plan.digest, bootstrap.plan_digest)
          raise ArgumentError, "The QuickBooks client-preparation preview changed. Build a new preview and review it again."
        end

        bootstrap.update!(status: "pending", apply_started_at: Time.current, apply_error: nil)
        record_audit!("historical_imports#queue_client_bootstrap")
        [ bootstrap, true ]
      end
    end

    def enqueue!(prepared)
      token = prepared.apply_started_at.iso8601(6)
      ClientBootstrapJob.perform_later(prepared.id, actor.id, token)
    rescue StandardError => e
      mark_enqueue_failed!(prepared, token)
      Rails.logger.error("Historical client bootstrap enqueue failed for bootstrap #{prepared.id}: #{e.class}: #{e.message}")
      raise ArgumentError, "Clean-client employee preparation could not be queued"
    end

    def mark_enqueue_failed!(prepared, token)
      prepared.with_lock do
        return unless prepared.pending? && prepared.apply_started_at&.iso8601(6) == token

        prepared.update!(status: "failed", apply_error: "Employee preparation could not be queued. Try again.")
        record_audit!("historical_imports#client_bootstrap_failed")
      end
    end

    def record_audit!(action)
      AuditLog.record!(
        user: actor,
        organization_id: bootstrap.company.organization_id,
        company_id: bootstrap.company_id,
        action: action,
        record_type: "historical_client_bootstraps",
        record_id: bootstrap.id,
        subject_name: bootstrap.historical_import_batch.source_label,
        metadata: {
          historical_import_batch_id: bootstrap.historical_import_batch_id,
          status: bootstrap.status,
          plan_digest: bootstrap.plan_digest
        }
      )
    end
  end
end
