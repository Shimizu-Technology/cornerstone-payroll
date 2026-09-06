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

      prepared, dispatch = prepare_pending_bootstrap!
      return Result.new(bootstrap: prepared, enqueued: false) unless dispatch

      Result.new(bootstrap: prepared, enqueued: dispatch.dispatch!)
    end

    private

    attr_reader :bootstrap, :actor, :acknowledgement

    def ensure_authorized!
      ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: bootstrap.company_id)
    end

    def prepare_pending_bootstrap!
      bootstrap.with_lock do
        bootstrap.reload
        return [ bootstrap, nil ] if bootstrap.applied?
        if bootstrap.pending?
          dispatch = bootstrap.historical_client_bootstrap_dispatches.find_or_create_by!(
            attempt_token: bootstrap.apply_started_at.iso8601(6)
          ) { |record| record.requested_by = actor }
          dispatch.update!(requested_by: actor) unless dispatch.requested_by
          return [ bootstrap, dispatch ]
        end

        plan = ClientBootstrapPlan.new(batch: bootstrap.historical_import_batch).call
        raise ArgumentError, plan.errors.join("; ") unless plan.ready?
        unless ActiveSupport::SecurityUtils.secure_compare(plan.digest, bootstrap.plan_digest)
          raise ArgumentError, "The QuickBooks client-preparation preview changed. Build a new preview and review it again."
        end

        bootstrap.update!(status: "pending", apply_started_at: Time.current, apply_error: nil)
        dispatch = bootstrap.historical_client_bootstrap_dispatches.create!(
          requested_by: actor,
          attempt_token: bootstrap.apply_started_at.iso8601(6)
        )
        record_audit!("historical_imports#queue_client_bootstrap", record: bootstrap)
        [ bootstrap, dispatch ]
      end
    end

    def record_audit!(action, record:)
      AuditLog.record!(
        user: actor,
        organization_id: record.company.organization_id,
        company_id: record.company_id,
        action: action,
        record_type: "historical_client_bootstraps",
        record_id: record.id,
        subject_name: record.historical_import_batch.source_label,
        metadata: {
          historical_import_batch_id: record.historical_import_batch_id,
          status: record.status,
          plan_digest: record.plan_digest
        }
      )
    end
  end
end
