# frozen_string_literal: true

module EmployeeVerificationItems
  class Review
    class Conflict < StandardError; end
    class Invalid < StandardError; end

    STAFF_EMPLOYEE_EDIT_ACTIONS = %w[employees#update employees#terminate employees#deactivate employees#reactivate].freeze

    def initialize(company_id:, item_id:, actor:)
      @company_id = company_id
      @item_id = item_id
      @actor = actor
    end

    def call!(operation, attributes)
      ApplicationRecord.transaction do
        company = Company.lock.find(@company_id)
        yield company
        item = EmployeeVerificationItem.where(company: company).lock.find(@item_id)
        validate_revision!(item, attributes[:updated_at])
        changes = case operation
        when :verify then verified_attributes(item, attributes)
        when :return_to_client then returned_attributes(item, attributes)
        else raise ArgumentError, "Unknown verification operation"
        end

        item.update!(changes.except(:staff_edit_audit_id))
        AuditLog.record!(
          user: @actor, company_id: company.id, organization_id: company.organization_id,
          action: "employee_verification_items##{operation}", record_type: "employee_verification_items",
          record_id: item.id, subject_name: item.employee.full_name,
          metadata: changes.except(:verified_by, :returned_by).merge(employee_id: item.employee_id, event_kind: item.event_kind)
        )
        PortalNotifications.employee_verification_returned!(item) if operation == :return_to_client
        item
      end
    end

    private

    def validate_revision!(item, revision)
      return if revision.nil? || revision == item.updated_at.utc.iso8601(6)

      raise Conflict, "This item changed. Refresh it before submitting a decision."
    end

    def verified_attributes(item, attributes)
      raise Conflict, "Only unverified items can be marked verified" unless item.open?

      note = attributes[:verification_note].to_s.strip
      raise Invalid, "Verification note must be 1,000 characters or fewer" if note.length > 1_000

      fixed = attributes[:fixed_by_staff].to_s == "true"
      audit_id = staff_edit_audit_id(item, attributes[:staff_edit_audit_id]) if fixed
      {
        status: "verified", verified_by: @actor, verified_at: Time.current, verification_note: note.presence,
        fixed_by_staff: fixed, staff_edit_audit_id: audit_id
      }
    end

    def staff_edit_audit_id(item, audit_id)
      edits = AuditLog.where(company_id: item.company_id, user_id: @actor.id, record_id: item.employee_id,
        created_at: item.updated_at.., view_as_grant_id: nil)
      edits = edits.where(record_type: "employees", action: STAFF_EMPLOYEE_EDIT_ACTIONS)
        .or(edits.where(record_type: "Employee", action: "employee#compensation_changed").where("metadata->>'source' = 'staff'"))
      edits = edits.where(id: audit_id) if audit_id.present?
      edits.newest_first.pick(:id) || raise(Invalid, "Save the employee fix before marking it verified")
    end

    def returned_attributes(item, attributes)
      raise Conflict, "Only pending verification items can be sent back" unless item.status == "pending_verification"

      note = attributes[:return_note].to_s.strip
      raise Invalid, "Return note must be between 5 and 1,000 characters" unless note.length.between?(5, 1_000)

      { status: "returned_to_client", returned_by: @actor, returned_at: Time.current, return_note: note }
    end
  end
end
