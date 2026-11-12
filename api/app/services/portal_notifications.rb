# frozen_string_literal: true

require "digest"

# Portal activity alerts. Events and their delivery ledger rows are written in
# the caller's domain transaction; PortalNotifications::Dispatcher sends email
# later. Real email stays off unless PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true,
# and rows recorded while it is off are created skipped, never pending.
module PortalNotifications
  TIME_ZONE = "Pacific/Guam"
  DIGEST_HOUR = 7
  DIGEST_TIME_LABEL = "7:00 AM Chamorro Time"
  # Immediate alerts wait briefly so a burst of activity becomes one email.
  BATCH_WINDOW = 2.minutes

  CATEGORIES = {
    "client_messages" => {
      audience: "staff", default_mode: "immediate", label: "Client messages",
      description: "A client sends a message or starts a conversation."
    },
    "client_uploads" => {
      audience: "staff", default_mode: "immediate", label: "Client file uploads",
      description: "A client uploads files. Several files sent together are one alert."
    },
    "employee_changes" => {
      audience: "staff", default_mode: "digest", label: "Employee change requests",
      description: "A client submits a new hire or employee change for review."
    },
    "portal_replies" => {
      audience: "client", default_mode: "immediate", label: "Messages from Cornerstone",
      description: "Cornerstone replies to you or starts a conversation."
    },
    "employee_change_decisions" => {
      audience: "client", default_mode: "digest", label: "Change request decisions",
      description: "Cornerstone approves or declines a change you requested."
    }
  }.freeze

  EVENT_TYPES = {
    "client_message" => { category: "client_messages", message: true },
    "client_upload" => { category: "client_uploads" },
    "employee_change_submitted" => { category: "employee_changes" },
    "staff_reply" => { category: "portal_replies", message: true },
    "employee_change_decided" => { category: "employee_change_decisions" }
  }.freeze

  class << self
    def delivery_enabled?
      ENV["PORTAL_EMAIL_NOTIFICATIONS_ENABLED"] == "true"
    end

    def message_created!(message)
      author = message.author
      event_type = if author&.client? then "client_message"
      elsif author&.staff_member? then "staff_reply"
      end
      return unless event_type

      record!(event_type: event_type, company: message.company, actor: author, subject: message.client_portal_thread,
        dedupe_key: "#{event_type}:message:#{message.id}", occurred_at: message.created_at,
        metadata: { message_id: message.id, thread_id: message.client_portal_thread_id,
                    attachment_count: message.client_document_id ? 1 : 0 })
    end

    def client_upload!(documents:, actor:)
      documents = Array(documents).sort_by(&:id)
      return if documents.empty? || !actor&.client?

      ids = documents.map(&:id)
      record!(event_type: "client_upload", company: documents.first.company, actor: actor, subject: documents.first,
        dedupe_key: "client_upload:documents:#{Digest::SHA256.hexdigest(ids.join(','))}",
        metadata: { document_ids: ids, document_count: ids.size })
    end

    def employee_change_submitted!(change_request)
      record!(event_type: "employee_change_submitted", company: change_request.company,
        actor: change_request.requested_by, subject: change_request,
        dedupe_key: "employee_change_submitted:#{change_request.id}",
        metadata: { change_request_id: change_request.id, request_kind: change_request.request_kind })
    end

    def employee_change_decided!(change_request, actor:)
      record!(event_type: "employee_change_decided", company: change_request.company, actor: actor, subject: change_request,
        dedupe_key: "employee_change_decided:#{change_request.id}:#{change_request.status}",
        metadata: { change_request_id: change_request.id, decision: change_request.status })
    end

    # Repeating an event (a retried request, a replayed job) returns the saved
    # event instead of creating more alerts.
    def record!(event_type:, company:, actor:, subject:, dedupe_key:, metadata: {}, occurred_at: Time.current)
      return if company.nil? || company.test_workspace?

      existing = PortalNotificationEvent.find_by(dedupe_key: dedupe_key)
      return existing if existing

      event = PortalNotificationEvent.new(
        organization_id: company.organization_id, company: company, actor: actor,
        event_type: event_type, category: EVENT_TYPES.fetch(event_type).fetch(:category),
        subject: subject, dedupe_key: dedupe_key, metadata: metadata, occurred_at: occurred_at || Time.current
      )
      targets, event.recipient_status = Recipients.resolve(event)
      begin
        PortalNotificationEvent.transaction(requires_new: true) { event.save! }
      rescue ActiveRecord::RecordNotUnique
        return PortalNotificationEvent.find_by!(dedupe_key: dedupe_key)
      end
      if targets.empty?
        # Never silently dropped: the ledger shows there was nobody to notify.
        PortalNotificationDelivery.create!(portal_notification_event: event, company_id: event.company_id, channel: "email",
          recipient_key: "none", delivery_mode: CATEGORIES.dig(event.category, :default_mode), status: "skipped",
          skip_reason: "no_recipients", deliver_after: event.occurred_at, completed_at: Time.current)
      end
      targets.each { |target| create_delivery!(event, target) }
      event
    end

    def next_digest_at(time)
      local = time.in_time_zone(TIME_ZONE)
      boundary = local.change(hour: DIGEST_HOUR, min: 0, sec: 0)
      boundary += 1.day if boundary <= local
      boundary
    end

    private

    def create_delivery!(event, target)
      # Extra addresses have no account preferences; they follow the default.
      mode = target.user ? Preferences.mode_for(target.user, event.category) : CATEGORIES.dig(event.category, :default_mode)
      attrs = { portal_notification_event: event, user: target.user, recipient_email: target.email,
                recipient_key: target.key, company_id: event.company_id, channel: "email" }
      skipped = ->(reason, delivery_mode = mode) do
        PortalNotificationDelivery.create!(attrs.merge(delivery_mode: delivery_mode, status: "skipped", skip_reason: reason,
          deliver_after: event.occurred_at, completed_at: Time.current))
      end
      # Rows recorded while email is off are final: enabling email later must
      # never send activity that happened before it was turned on.
      if !delivery_enabled?
        skipped.call("email_delivery_disabled", mode == "off" ? CATEGORIES.dig(event.category, :default_mode) : mode)
      elsif mode == "off"
        skipped.call("preference_off", CATEGORIES.dig(event.category, :default_mode))
      elsif coalesced?(event, target)
        skipped.call("coalesced")
      else
        deliver_after = mode == "digest" ? next_digest_at(event.occurred_at) : event.occurred_at + BATCH_WINDOW
        PortalNotificationDelivery.create!(attrs.merge(delivery_mode: mode, status: "pending", deliver_after: deliver_after))
      end
    end

    # One alert per unread conversation burst: a later message in a conversation
    # this person was already alerted about, and has not opened since, is
    # recorded but does not send another email. Extra addresses cannot open the
    # conversation, so they coalesce only with an alert still waiting to send.
    def coalesced?(event, target)
      return false unless event.message_event? && event.subject.is_a?(ClientPortalThread)

      scope = PortalNotificationDelivery.joins(:portal_notification_event)
        .where(recipient_key: target.key)
        .where(portal_notification_events: { subject_type: "ClientPortalThread", subject_id: event.subject_id })
      return scope.pending.exists? unless target.user

      opened_at = PortalThreadReadReceipt.where(client_portal_thread_id: event.subject_id, user_id: target.user.id).pick(:opened_at)
      scope = scope.where(status: %w[pending sent])
      scope = scope.where("portal_notification_deliveries.created_at > ?", opened_at) if opened_at
      scope.exists?
    end
  end
end
