# frozen_string_literal: true

module EmployeeDocuments
  # Provider delivery events (delivered, delayed, bounced, complained) for
  # employee document notices (M4-5).
  #
  # Every verified webhook event is stored first (EmailProviderEvent, unique
  # on the Svix event id, so a replay changes nothing), and only then matched
  # to the notice whose provider_message_id it names. A notice records that
  # id when the send commits, which can be after a fast bounce arrives, so
  # the send commit and the periodic sweep (DispatchEmployeeTaxFormNoticesJob)
  # reconcile any stored events too.
  #
  # Events apply oldest first. An event older than the one already applied
  # never overwrites it, a bounce or complaint is final, and a later
  # "delayed" never hides a delivery. Events for other email (staff and
  # client notifications) match no notice and are pruned after
  # EmailProviderEvent::RETENTION.
  module NoticeDeliveryEvent
    RANK = { "unknown" => 0, "delayed" => 1, "delivered" => 2, "bounced" => 3, "complained" => 3 }.freeze
    PROVIDER = "resend"
    SWEEP_LIMIT = 500

    module_function

    # Stores one verified event and applies it when its notice is known.
    # Returns the stored event, or nil for a replay of an event already kept.
    def record!(event_id:, event_type:, message_id:, status:, bounce_type: nil, occurred_at: nil)
      event = store!(event_id: event_id, event_type: event_type, message_id: message_id, status: status,
        bounce_type: bounce_type, occurred_at: occurred_at)
      reconcile!(event.provider_message_id) if event&.delivery_status && event.provider_message_id
      event
    end

    def store!(event_id:, event_type:, message_id:, status:, bounce_type:, occurred_at:)
      status = nil unless EmailProviderEvent::DELIVERY_STATUSES.include?(status)
      now = Time.current
      row = {
        provider: PROVIDER, event_id: event_id.to_s.first(255), event_type: event_type.to_s.first(100).presence || "unknown",
        provider_message_id: (message_id.first(255).presence if message_id.is_a?(String)), delivery_status: status,
        bounce_type: (bounce_type.to_s.first(64).presence if status == "bounced"),
        occurred_at: parse_time(occurred_at) || now, created_at: now, updated_at: now
      }
      inserted = EmailProviderEvent.insert_all([ row ], unique_by: :idx_email_provider_events_once, returning: %w[id])
      id = inserted.rows.first&.first
      EmailProviderEvent.find(id) if id
    end

    # Applies the stored, not yet applied events for one provider message id
    # to its notice, oldest first. Returns the notice, or nil when none has
    # that id yet (the events wait for it).
    def reconcile!(message_id)
      return unless message_id.is_a?(String) && message_id.present?

      within_scope do |company_id|
        EmployeeDocumentNotice.transaction do
          notices = EmployeeDocumentNotice.where(provider_message_id: message_id)
          notices = notices.where(company_id: company_id) if company_id
          notice = notices.lock.first
          next unless notice

          events = EmailProviderEvent.unapplied.where(provider: PROVIDER, provider_message_id: message_id)
            .order(:occurred_at, :id).lock.to_a
          events.each do |event|
            PaperTaxFormFollowUp.record!(notice, event)
            apply!(notice, event)
            event.update!(applied_at: Time.current)
          end
          notice
        end
      end
    end

    # Reconciles stored events whose notice now has their provider id, and
    # prunes events kept past retention. Run by the notice sweep.
    def sweep!(limit: SWEEP_LIMIT)
      TenantScope.as_system(reason: "Reconcile stored email provider events with employee document notices") do
        ids = EmailProviderEvent.unapplied.where(provider: PROVIDER)
          .where(provider_message_id: EmployeeDocumentNotice.where.not(provider_message_id: nil).select(:provider_message_id))
          .order(:provider_message_id).distinct.limit(limit).pluck(:provider_message_id)
        ids.each { |id| reconcile!(id) }
        EmailProviderEvent.where(created_at: ...EmailProviderEvent::RETENTION.ago).in_batches(of: 1_000).delete_all
        ids.size
      end
    end

    # The webhook and the sweep run unscoped and match across companies; a
    # send commit runs inside its company's scope and keeps to it.
    def within_scope
      context = TenantScope.current
      return yield(context.mode == "company" ? context.company_id : nil) if context

      TenantScope.as_system(reason: "Match an email provider delivery event to its employee document notice") { yield nil }
    end

    def apply!(notice, event)
      status = event.delivery_status
      return false if EmployeeDocumentNotice::FINAL_DELIVERY_STATUSES.include?(notice.delivery_status)
      return false if notice.delivery_event_at && event.occurred_at < notice.delivery_event_at
      return false if RANK.fetch(status) < RANK.fetch(notice.delivery_status)

      notice.update!(delivery_status: status, delivery_event_at: event.occurred_at,
        bounce_type: (event.bounce_type if status == "bounced"))
      audit_problem!(notice) if EmployeeDocumentNotice::FINAL_DELIVERY_STATUSES.include?(status)
      true
    end

    def parse_time(value)
      Time.zone.parse(value.to_s) if value.is_a?(String) && value.present?
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
