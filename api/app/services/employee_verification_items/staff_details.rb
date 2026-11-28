# frozen_string_literal: true

module EmployeeVerificationItems
  class StaffDetails
    def self.summary(item)
      {
        id: item.id, employee_id: item.employee_id, employee_name: item.employee.full_name,
        company_id: item.company_id, event_kind: item.event_kind, status: item.status, affects_pay: item.affects_pay,
        source_actor_id: item.source_actor_id, source_actor_name: item.source_actor&.name,
        effective_on: item.effective_on, created_at: item.created_at, updated_at: item.updated_at.utc.iso8601(6)
      }
    end

    def initialize(item, viewer:)
      @item = item
      @employee = item.employee
      @viewer = viewer
    end

    def as_json
      checklist = EmployeeReadinessEvaluator.evaluate(@employee)
      acknowledgements = @item.pay_period_verification_acknowledgements.order(:id)
        .as_json(only: %i[id pay_period_id acknowledged_by_id acknowledged_at item_status_snapshot item_updated_at_snapshot])
      audit_entries = AuditLog.where(company_id: @item.company_id, record_id: @item.id,
        record_type: "employee_verification_items").oldest_first
      {
        **self.class.summary(@item),
        changed_fields: @item.changed_fields,
        before_values: Recorder.sanitize_values(@item.before_values),
        after_values: Recorder.sanitize_values(@item.after_values),
        readiness_checklist: checklist.as_json,
        return_note: @item.return_note, returned_at: @item.returned_at, returned_by_id: @item.returned_by_id,
        resubmitted_at: @item.resubmitted_at, client_response_note: @item.metadata["client_response_note"],
        verification_note: @item.verification_note, verified_at: @item.verified_at, verified_by_id: @item.verified_by_id,
        fixed_by_staff: @item.fixed_by_staff, source_record_type: @item.source_record_type, source_record_id: @item.source_record_id,
        prior_unverified_item_id: @item.metadata["prior_unverified_item_id"], superseded_by_id: @item.superseded_by_id,
        audit_references: audit_entries.map { |entry| serialize_audit(entry) },
        commit_acknowledgements: acknowledgements,
        can_review: @item.open? && StaffRolePolicy.allowed?(@viewer, :manage_client_configuration, company: @employee.company),
        warnings: warnings(checklist, acknowledgements)
      }
    end

    private

    def serialize_audit(entry)
      {
        id: entry.id, action: entry.action, user_id: entry.user_id, created_at: entry.created_at,
        return_note: entry.metadata["return_note"], staff_edit_audit_id: entry.metadata["staff_edit_audit_id"]
      }
    end

    def warnings(checklist, acknowledgements)
      {
        committed_pay_period_ids: acknowledgements.pluck("pay_period_id"),
        review_final_pay: @item.event_kind == "termination",
        post_termination_committed_pay_period_ids: @item.metadata["post_termination_committed_pay_period_ids"] || [],
        direct_deposit_missing_bank_details: checklist.direct_deposit_missing_bank_details?,
        tax_filing_impact: @item.metadata["tax_filing_impact"],
        possible_self_created_hire: @item.metadata["possible_self_created_hire"] == true,
        approved_pay_period_ids: approved_pay_period_ids
      }
    end

    def approved_pay_period_ids
      @employee.payroll_items.financially_reportable.joins(:pay_period)
        .where(company_id: @item.company_id, pay_periods: { company_id: @item.company_id, status: "approved" })
        .distinct.order(:pay_period_id).pluck(:pay_period_id)
    end
  end
end
