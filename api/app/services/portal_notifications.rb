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
    "admin_override_staff" => {
      audience: "staff", default_mode: "immediate", label: "Administrative changes",
      description: "A privileged change was made for a client."
    },
    "payroll_finalized" => {
      audience: "client", default_mode: "digest", label: "Payroll finalized",
      description: "Payroll is final and pay statements post on pay date."
    },
    "payroll_corrections" => {
      audience: "client", default_mode: "immediate", label: "Payroll reopened",
      description: "A finalized payroll was rolled back or reopened."
    },
    "payroll_corrections_staff" => {
      audience: "staff", default_mode: "immediate", label: "Payroll reopened",
      description: "A client's payroll was rolled back or reopened."
    },
    "payroll_super_admin" => {
      audience: "staff", default_mode: "immediate", mandatory: true, label: "Payroll oversight",
      description: "A payroll action requires super-admin visibility."
    },
    "payroll_viewer_updates" => {
      audience: "client", default_mode: "digest", label: "Payroll decisions",
      description: "Cornerstone records a decision on a payroll."
    },
    "contact_confirmations" => {
      audience: "staff", default_mode: "digest", label: "Contact changes to confirm",
      description: "An employee contact or delivery change needs confirmation."
    },
    "employee_app_follow_ups" => {
      audience: "staff", default_mode: "digest", label: "Employee app follow-ups",
      description: "Employee sign-ups are locked or invites are expiring."
    },
    "w2_posting" => {
      audience: "staff", default_mode: "immediate", label: "W-2s ready to post",
      description: "The current W-2 filing was marked ready."
    },
    "tax_form_paper_copies" => {
      audience: "staff", default_mode: "immediate", label: "Paper tax form follow-ups",
      description: "An employee tax form email could not be delivered and a paper copy is due."
    },
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
    },
    "address_approvals" => {
      audience: "client", default_mode: "immediate", label: "Address requests to review",
      description: "An employee submits an address request for approval."
    },
    "contact_changes" => {
      audience: "client", default_mode: "digest", label: "Employee contact changes",
      description: "An employee or client user updates employee contact details."
    },
    "employee_address_decisions" => {
      audience: "employee", default_mode: "immediate", label: "Address request decisions",
      description: "Your address request was approved or declined."
    },
    "payroll_submissions" => {
      audience: "staff", default_mode: "immediate", label: "Pay period files and approvals",
      description: "A client sends a pay period's payroll files, approves a draft or asks for a change."
    },
    "payroll_updates" => {
      audience: "client", default_mode: "immediate", label: "Pay period updates",
      description: "Cornerstone confirms your payroll files arrived or posts a draft for your review."
    }
  }.freeze

  EVENT_TYPES = {
    "admin_override" => { category: "admin_override_staff", scopes: {
      "account_team" => "admin_override_staff", "super_admins" => "payroll_super_admin",
      "client_managers" => "payroll_updates"
    } },
    "payroll_committed" => { category: "payroll_finalized", scopes: {
      "client_managers" => "payroll_finalized", "client_viewers" => "payroll_finalized"
    } },
    "payroll_reopened" => { category: "payroll_corrections", scopes: {
      "client_managers" => "payroll_corrections", "client_viewers" => "payroll_viewer_updates",
      "account_team" => "payroll_corrections_staff", "super_admins" => "payroll_super_admin"
    } },
    "employee_signup_locked" => { category: "employee_app_follow_ups" },
    "employee_invite_expiring" => { category: "employee_app_follow_ups" },
    "w2_ready_to_post" => { category: "w2_posting" },
    "tax_form_paper_required" => { category: "tax_form_paper_copies" },
    "client_message" => { category: "client_messages", message: true },
    "client_upload" => { category: "client_uploads" },
    "employee_change_submitted" => { category: "employee_changes" },
    "address_approval_requested" => { category: "address_approvals", client_managers_only: true },
    "employee_contact_confirmation_requested" => { category: "contact_confirmations" },
    "employee_contact_changed" => { category: "contact_changes", client_managers_only: true },
    "employee_address_decided" => { category: "employee_address_decisions" },
    "staff_reply" => { category: "portal_replies", message: true },
    "employee_change_decided" => { category: "employee_change_decisions" },
    "payroll_submission_sent" => { category: "payroll_submissions" },
    "payroll_draft_decided" => { category: "payroll_submissions" },
    "payroll_submission_imported" => { category: "payroll_updates" },
    "payroll_submission_acknowledged" => { category: "payroll_updates" },
    "payroll_review_published" => { category: "payroll_updates", client_managers_only: true },
    "payroll_review_decided" => { category: "payroll_submissions" },
    "payroll_draft_posted" => { category: "payroll_updates" },
    # File requests ride the conversation alerts, one alert per unread burst.
    "file_requested" => { category: "portal_replies", message: true },
    "file_request_reviewed" => { category: "portal_replies", message: true },
    "file_request_responded" => { category: "client_messages", message: true }
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
                    attachment_count: message.attachment_ids.size })
    end

    # A typed request step replaces the generic message alert for its message.
    def file_request_step!(event_type, request:, message:)
      record!(event_type: event_type, company: request.company, actor: message.author, subject: request.client_portal_thread,
        dedupe_key: "#{event_type}:message:#{message.id}", occurred_at: message.created_at,
        metadata: { file_request_id: request.id, message_id: message.id, thread_id: request.client_portal_thread_id,
                    status: request.status, attachment_count: message.attachment_ids.size,
                    payroll_submission_period_id: request.payroll_submission_period_id }.compact)
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
      if change_request.profile_address?
        record!(event_type: "address_approval_requested", company: change_request.company,
          actor: change_request.requested_by, subject: change_request,
          dedupe_key: "address_approval_requested:#{change_request.id}")
      end
    end

    def employee_contact_changed!(entry, actor: entry.changed_by)
      record!(event_type: "employee_contact_changed", company: entry.company, actor: actor,
        subject: entry, dedupe_key: "employee_contact_changed:#{entry.id}")
      unless entry.after_values.key?("emergency_contacts")
        record!(event_type: "employee_contact_confirmation_requested", company: entry.company, actor: actor,
          subject: entry, dedupe_key: "employee_contact_confirmation_requested:#{entry.id}")
      end
    end

    def delivery_consent_withdrawn!(entry, actor: entry.changed_by)
      record!(event_type: "employee_contact_confirmation_requested", company: entry.company, actor: actor,
        subject: entry, dedupe_key: "employee_contact_confirmation_requested:#{entry.id}")
    end

    def employee_address_decided!(change_request, actor:)
      record!(event_type: "employee_address_decided", company: change_request.company, actor: actor,
        subject: change_request, dedupe_key: "employee_address_decided:#{change_request.id}:#{change_request.status}")
    end

    def employee_change_decided!(change_request, actor:)
      record!(event_type: "employee_change_decided", company: change_request.company, actor: actor, subject: change_request,
        dedupe_key: "employee_change_decided:#{change_request.id}:#{change_request.status}",
        metadata: { change_request_id: change_request.id, decision: change_request.status })
    end

    def payroll_submission_sent!(submission)
      payroll_period!("payroll_submission_sent", period: submission.period, actor: submission.submitted_by,
        dedupe: "submission:#{submission.id}", metadata: { submission_id: submission.id, revision: submission.revision })
    end

    # Approvals, change requests, receipts and posted drafts. Metadata keeps
    # record ids only; the period subject carries the company.
    def payroll_period!(event_type, period:, actor:, dedupe:, metadata: {})
      record!(event_type: event_type, company: period.company, actor: actor, subject: period,
        dedupe_key: "#{event_type}:#{dedupe}", metadata: metadata.merge(period_id: period.id))
    end

    def payroll_committed!(period, actor:)
      payroll_lifecycle_event!("payroll_committed", period, actor: actor, revision: period.committed_at.utc.iso8601(6))
    rescue StandardError => error
      Rails.logger.error("Payroll commit notification failed: period=#{period.id} error=#{error.class}")
    end

    # Record the alert in the rollback transaction with its immutable action ID.
    # Let ledger errors propagate so the rollback and its audit writes fail.
    def admin_override!(entry, client_managers: false)
      scopes = %w[account_team super_admins]
      scopes << "client_managers" if client_managers
      scopes.each do |scope|
        record!(event_type: "admin_override", company: entry.company, actor: entry.actor, subject: entry.company,
          dedupe_key: "admin_override:#{entry.id}:#{scope}", metadata: { recipient_scope: scope })
      end
    end

    def payroll_reopened!(period, actor:, action_id:, self_override: false)
      raise ArgumentError, "Payroll rollback action ID is required" if action_id.blank?

      payroll_lifecycle_event!("payroll_reopened", period, actor: actor, revision: action_id, self_override: self_override)
    end

    def employee_link_event!(event_type, link, generation:, now: Time.current)
      record!(event_type: event_type, company: link.company, actor: nil, subject: link,
        dedupe_key: "#{event_type}:#{link.id}:#{generation.utc.iso8601(6)}",
        metadata: { generation: generation.utc.iso8601(6) }, occurred_at: now)
    end

    def w2_ready_to_post!(filing, actor:)
      ApplicationRecord.transaction(requires_new: true) do
        revision = filing.attestation_history.length
        dedupe_key = "w2_ready_to_post:#{filing.id}:#{revision}"
        next if PortalNotificationEvent.exists?(dedupe_key: dedupe_key)
        next unless EmployeeDocuments::PostW2GuCopies.new(company: filing.company, year: filing.year).posting_pending?

        record!(event_type: "w2_ready_to_post", company: filing.company, actor: actor, subject: filing,
          dedupe_key: dedupe_key, metadata: { tax_year: filing.year, revision: revision },
          w2_posting_availability: { [ filing.company_id, filing.year, revision ] => true })
      end
    rescue StandardError => error
      Rails.logger.error("W-2 posting notification failed: filing=#{filing.id} error=#{error.class}")
    end

    # TODO(PR4): Wire lifecycle_mode_activation_blocked into CATEGORIES,
    # EVENT_TYPES, Recipients (listed :manage_client_configuration staff with
    # org_admin/super_admin fallback), and Email templates. Kept as an explicit
    # no-op in PR 3 so PR 4's change is visible and activation never depends on
    # a silent respond_to? hook.
    def lifecycle_mode_activation_blocked!(_profile, actor: nil)
      nil
    end

    # Repeating an event (a retried request, a replayed job) returns the saved
    # event instead of creating more alerts.
    def record!(event_type:, company:, actor:, subject:, dedupe_key:, metadata: {}, occurred_at: Time.current, w2_posting_availability: {})
      # Practice copies never notify. A demo company notifies like a client,
      # but only allow-listed recipients (DemoOutbound) are ever sent to.
      return if company.nil? || company.practice_copy?

      existing = PortalNotificationEvent.find_by(dedupe_key: dedupe_key)
      return existing if existing

      definition = EVENT_TYPES.fetch(event_type)
      scope = metadata.stringify_keys["recipient_scope"]
      category = definition[:scopes]&.fetch(scope) || definition.fetch(:category)
      if event_type == "payroll_review_decided" && scope == "super_admins"
        category = "payroll_super_admin"
      elsif event_type == "payroll_review_decided" && scope == "client_viewers"
        category = "payroll_viewer_updates"
      elsif event_type == "payroll_review_decided" && metadata.stringify_keys.slice("decision", "recipient_scope") ==
          { "decision" => "cornerstone_override", "recipient_scope" => "client_managers" }
        category = "payroll_updates"
      end
      event = PortalNotificationEvent.new(
        organization_id: company.organization_id, company: company, actor: actor,
        event_type: event_type, category: category,
        subject: subject, dedupe_key: dedupe_key, metadata: metadata, occurred_at: occurred_at || Time.current
      )
      targets, event.recipient_status = Recipients.resolve(event, now: event.occurred_at, w2_posting_availability: w2_posting_availability)
      begin
        PortalNotificationEvent.transaction(requires_new: true) { event.save! }
      rescue ActiveRecord::RecordNotUnique
        return PortalNotificationEvent.find_by!(dedupe_key: dedupe_key)
      end
      if targets.empty?
        # Never silently dropped: the ledger shows there was nobody to notify.
        PortalNotificationDelivery.create!(portal_notification_event: event, company_id: event.company_id, channel: "email",
          recipient_key: "none", delivery_mode: CATEGORIES.dig(event.category, :default_mode), status: "skipped",
          skip_reason: event.recipient_status, deliver_after: event.occurred_at, completed_at: Time.current)
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

    def deliver_after_for(mode, occurred_at)
      mode == "digest" ? next_digest_at(occurred_at) : occurred_at + BATCH_WINDOW
    end

    private

    def payroll_lifecycle_event!(event_type, period, actor:, revision:, self_override: false)
      ApplicationRecord.transaction(requires_new: true) do
        EVENT_TYPES.fetch(event_type).fetch(:scopes).each_key do |scope|
          metadata = { recipient_scope: scope, revision: revision }
          metadata[:self_override] = true if scope == "super_admins" && self_override
          payroll_period!(event_type, period: period, actor: actor, dedupe: "#{period.id}:#{revision}:#{scope}",
            metadata: metadata)
        end
      end
    end

    def create_delivery!(event, target)
      # Extra addresses have no account preferences; they follow the default.
      mode = target.user ? Preferences.mode_for(target.user, event.category) : CATEGORIES.dig(event.category, :default_mode)
      ledger_mode = mode == "off" ? CATEGORIES.dig(event.category, :default_mode) : mode
      intended_email = PortalNotificationRecipient.normalize_email(target.user&.email || target.email)
      attrs = { portal_notification_event: event, user: target.user, recipient_email: target.email,
                intended_recipient_email: intended_email, recipient_key: target.key, company_id: event.company_id, channel: "email" }
      skipped = ->(reason, delivery_mode = ledger_mode, deliver_after: event.occurred_at) do
        PortalNotificationDelivery.create!(attrs.merge(delivery_mode: delivery_mode, status: "skipped", skip_reason: reason,
          deliver_after: deliver_after, completed_at: Time.current))
      end
      # Rows recorded while email is off are final: enabling email later must
      # never send activity that happened before it was turned on.
      if !DemoOutbound.permit?(company: event.company, email: target.user&.email || target.email, channel: "portal_notification", user: target.user)
        skipped.call("recipient_not_allowed")
      elsif !delivery_enabled?
        skipped.call("email_delivery_disabled")
      elsif !Transport.configured?
        skipped.call("email_not_configured")
      elsif mode == "off"
        skipped.call("preference_off")
      elsif coalesced?(event, target)
        skipped.call("coalesced")
      else
        deliver_after = deliver_after_for(mode, event.occurred_at)
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
