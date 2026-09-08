# frozen_string_literal: true

module QuickbooksHistory
  class YtdBridgeApplyService
    ACKNOWLEDGEMENT = "ACTIVATE VERIFIED HISTORICAL YTD"

    def initialize(bridge:, actor:, acknowledgement:)
      @bridge = bridge
      @actor = actor
      @acknowledgement = acknowledgement
    end

    def call
      ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: bridge.company_id)
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
      return bridge if bridge.applied?

      HistoricalYtdBridge.transaction do
        bridge.company.lock!
        bridge.historical_import_batch.lock!
        bridge.lock!
        next bridge if bridge.applied?

        plan = YtdBridgePlan.new(batch: bridge.historical_import_batch).call
        raise ArgumentError, plan.errors.join("; ") unless plan.ready?
        unless ActiveSupport::SecurityUtils.secure_compare(plan.digest, bridge.plan_digest)
          raise ArgumentError, "The historical YTD preview changed. Build a new preview and review it again."
        end

        timestamp = Time.current
        rows = plan.balances.map do |balance|
          balance.except("employee_name").merge(
            "historical_ytd_bridge_id" => bridge.id,
            "created_at" => timestamp,
            "updated_at" => timestamp
          )
        end
        rows.each do |attributes|
          candidate = HistoricalEmployeeYtdBalance.new(attributes)
          next if candidate.valid?

          raise ArgumentError,
                "Historical YTD balance for employee #{attributes['employee_id']} tax year " \
                "#{attributes['tax_year']} is invalid: #{candidate.errors.full_messages.join('; ')}"
        end
        HistoricalEmployeeYtdBalance.insert_all!(rows)
        bridge.update!(
          status: "applied",
          applied_by: actor,
          applied_at: timestamp,
          apply_acknowledgement: acknowledgement
        )
        record_adjustment_activation_events!(plan, timestamp)
        record_audit!(plan)
        bridge
      end
    end

    private

    attr_reader :bridge, :actor, :acknowledgement

    def record_audit!(plan)
      AuditLog.record!(
        user: actor,
        organization_id: bridge.company.organization_id,
        company_id: bridge.company_id,
        action: "historical_imports#apply_ytd_bridge",
        record_type: "historical_ytd_bridges",
        record_id: bridge.id,
        subject_name: bridge.historical_import_batch.source_label,
        metadata: {
          historical_import_batch_id: bridge.historical_import_batch_id,
          revision: bridge.revision,
          plan_digest: plan.digest,
          employee_count: plan.summary.fetch("employee_count"),
          balance_count: plan.summary.fetch("balance_count"),
          through_pay_date: plan.summary.fetch("through_pay_date")
        }
      )
    end

    def record_adjustment_activation_events!(plan, timestamp)
      adjustment_ids = Array(plan.summary["adjustment_ids"])
      adjustment_ids.each do |adjustment_id|
        HistoricalPaycheckAdjustmentEvent.create!(
          company: bridge.company,
          historical_paycheck_adjustment_id: adjustment_id,
          historical_ytd_bridge: bridge,
          created_by: actor,
          event_type: "ytd_revision_activated",
          metadata: { "revision" => bridge.revision, "plan_digest" => plan.digest },
          created_at: timestamp
        )
      end
    end
  end
end
