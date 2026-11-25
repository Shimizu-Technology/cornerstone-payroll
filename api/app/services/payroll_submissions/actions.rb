# frozen_string_literal: true

module PayrollSubmissions
  # Status changes, drafts and period messages. Each runs in one transaction
  # with the period row locked: status, history, audit entry and notification
  # are saved together or not at all.
  class Actions
    class Conflict < StandardError; end

    def initialize(company:, actor:, catalog:, request_context: {})
      @company = company
      @actor = actor
      @catalog = catalog
      @request_context = request_context
    end

    # Staff confirm they received this exact revision.
    def acknowledge!(period, submission_id:)
      locked(period) do
        submission = period.submissions.find_by(id: submission_id.to_s.to_i)
        raise ActiveRecord::RecordNotFound, "Submission not found" unless submission

        current = period.submissions.first
        raise Conflict, "A newer revision arrived. Review revision #{current.revision} instead." if submission != current
        next submission if submission.acknowledged?

        submission.update!(acknowledged_by: @actor, acknowledged_at: Time.current)
        period.transition!("acknowledge", actor: @actor, submission: submission)
        audit!(period, "payroll_submission_periods#acknowledge", submission_id: submission.id, revision: submission.revision)
        PortalNotifications.payroll_period!("payroll_submission_acknowledged", period: period, actor: @actor,
          dedupe: "submission:#{submission.id}", metadata: { submission_id: submission.id, revision: submission.revision })
        submission
      end
    end

    def start_review!(period, note: nil)
      locked(period) do
        raise PayrollSubmissionPeriod::TransitionError, "This pay run is committed. Continue the conversation in messages." if period.pay_period&.client_finished?
        next if period.status == "in_review"

        period.transition!("start_review", actor: @actor, note: note)
        audit!(period, "payroll_submission_periods#start_review")
      end
    end

    def mark_paid!(period, note: nil)
      raise PayrollSubmissionPeriod::TransitionError, "Review the preview on the pay run. Payroll files finish when the pay run is committed."
    end

    # Retired write routes give older clients a clear recovery path.
    def decide!(period, decision:, draft_id:, note:)
      raise PayrollSubmissionPeriod::TransitionError, "Review the preview on the pay run. Payroll files finish when the pay run is committed."
    end

    def create_draft!(entry, params:)
      raise PayrollSubmissionPeriod::TransitionError, "Review the preview on the pay run. Payroll files finish when the pay run is committed."
    end

    def post_draft!(period, draft_id:)
      raise PayrollSubmissionPeriod::TransitionError, "Review the preview on the pay run. Payroll files finish when the pay run is committed."
    end

    # A question or answer about this period, in its own conversation.
    def post_message!(entry, body:, idempotency_key:, document_ids: [])
      body = body.to_s.strip
      documents = PortalMessages::Attachments.resolve!(company_id: @company.id, user: @actor, ids: document_ids)
      raise PayrollSubmissionPeriod::TransitionError, "Write a message first" if body.blank? && documents.empty?
      raise PayrollSubmissionPeriod::TransitionError, "Keep messages under 5,000 characters" if body.length > 5000

      message = nil
      replayed = false
      PayrollSubmissionPeriod.transaction do
        period = @catalog.materialize!(entry)
        period.lock!
        thread = period.client_portal_thread
        key = idempotency_key.presence&.to_s&.first(128)
        if thread && key && (message = thread.messages.find_by(author_id: @actor.id, idempotency_key: key))
          unless message.body.to_s == body && message.attachment_ids == documents.map(&:id)
            raise Conflict, "This retry key was used for a different message"
          end

          replayed = true
          next
        end
        message = create_message!(period, body, key, documents: documents)
        PortalNotifications.message_created!(message)
      end
      ClientPortalThreadChannel.broadcast_thread(message.client_portal_thread, event: "message_created") unless replayed
      [ message, replayed ]
    end

    private

    def locked(period)
      PayrollSubmissionPeriod.transaction do
        period.lock!
        yield
      end
    end

    def create_message!(period, body, key, documents: [])
      thread = ensure_thread!(period)
      message = ClientPortalMessage.create!(client_portal_thread: thread, company_id: period.company_id,
        author: @actor, body: body.presence, idempotency_key: key, attach_documents: documents)
      PortalActivity.record!(user: @actor, record: message, action: "client_portal_messages#create",
        metadata: PortalActivity.message_metadata(message).merge(payroll_submission_period_id: period.id), **@request_context.slice(:ip_address, :user_agent))
      message
    end

    def ensure_thread!(period)
      return period.client_portal_thread if period.client_portal_thread

      thread = ClientPortalThread.create!(company_id: period.company_id, created_by: @actor, subject: "Payroll #{period.label}")
      period.update!(client_portal_thread: thread)
      PortalActivity.record!(user: @actor, record: thread, action: "client_portal_threads#create",
        metadata: { subject: thread.subject, payroll_submission_period_id: period.id }, **@request_context.slice(:ip_address, :user_agent))
      thread
    end

    def audit!(period, action, metadata = {})
      Audit.record!(actor: @actor, period: period, action: action, metadata: metadata, request_context: @request_context)
    end
  end
end
