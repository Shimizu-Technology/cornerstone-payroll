# frozen_string_literal: true

module EmployeeDocuments
  # Applies a provider delivery event (delivered, delayed, bounced,
  # complained) to the employee document notice it belongs to. A bounce or
  # complaint is final; a later "delivered" never hides it. Events for other
  # email (staff and client notifications) match no notice and are ignored.
  module NoticeDeliveryEvent
    RANK = { "unknown" => 0, "delayed" => 1, "delivered" => 2, "bounced" => 3, "complained" => 3 }.freeze

    module_function

    # Returns the updated notice, or nil when none matched or nothing changed.
    def record!(message_id:, status:, bounce_type: nil, occurred_at: nil)
      return unless RANK.key?(status) && status != "unknown" && message_id.is_a?(String) && message_id.present?

      TenantScope.as_system(reason: "Match an email provider delivery event to its employee document notice") do
        EmployeeDocumentNotice.transaction do
          notice = EmployeeDocumentNotice.lock.find_by(provider_message_id: message_id)
          next unless notice
          next if EmployeeDocumentNotice::FINAL_DELIVERY_STATUSES.include?(notice.delivery_status)
          next if RANK.fetch(status) < RANK.fetch(notice.delivery_status)

          at = (Time.zone.parse(occurred_at.to_s) if occurred_at.present?) || Time.current
          notice.update!(delivery_status: status, delivery_event_at: at,
            bounce_type: (bounce_type.to_s.first(64).presence if status == "bounced"))
          audit_problem!(notice) if EmployeeDocumentNotice::FINAL_DELIVERY_STATUSES.include?(status)
          notice
        end
      end
    rescue ArgumentError
      nil
    end

    # A bounce or complaint is recorded for staff, without the address.
    def audit_problem!(notice)
      company = notice.company
      AuditLog.record!(
        actor: AuditActor.system_job(name), organization_id: company.organization_id, company_id: company.id,
        action: "employee_tax_forms#notice_#{notice.delivery_status}", record_type: "EmployeeDocumentNotice",
        record_id: notice.id, subject_name: notice.employee&.display_name, event_category: "employee_portal",
        metadata: { employee_document_id: notice.employee_document_id, employee_id: notice.employee_id,
                    bounce_type: notice.bounce_type }.compact
      )
    end
  end
end
