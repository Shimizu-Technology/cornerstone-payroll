# frozen_string_literal: true

class EmployeeDocumentRequirementPresenter
  def self.call(requirement, client: false)
    document = requirement.client_document
    document_visible = document.present? && (!client || document.visible_to_client?)
    payload = {
      id: requirement.id,
      employee_id: requirement.employee_id,
      requirement_type: requirement.requirement_type,
      label: requirement.label,
      status: requirement.status,
      required_for_payroll: requirement.required_for_payroll,
      due_on: requirement.due_on,
      received_at: requirement.received_at,
      reviewed_at: requirement.reviewed_at,
      reviewed_by_name: client ? nil : requirement.reviewed_by&.name,
      review_note: client ? nil : requirement.review_note,
      lock_version: requirement.lock_version,
      document_attached: document.present?,
      client_document_id: document_visible ? document.id : nil,
      document_title: document_visible ? document.title : nil,
      updated_at: requirement.updated_at
    }
    return payload if client

    payload.merge(
      history: requirement.events.order(created_at: :desc, id: :desc).map do |event|
        {
          id: event.id,
          event_type: event.event_type,
          from_status: event.from_status,
          to_status: event.to_status,
          document_title: event.document_title,
          actor_name: event.actor&.name,
          note: event.note,
          created_at: event.created_at
        }
      end
    )
  end
end
