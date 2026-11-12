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
        next if period.status == "in_review"

        period.transition!("start_review", actor: @actor, note: note)
        audit!(period, "payroll_submission_periods#start_review")
      end
    end

    def mark_paid!(period, note: nil)
      locked(period) do
        next if period.status == "paid"

        period.transition!("mark_paid", actor: @actor, note: note, draft: period.current_draft)
        audit!(period, "payroll_submission_periods#mark_paid", note_present: note.present?)
      end
    end

    # The client approves the current posted draft or asks for a change. The
    # note also goes into the period conversation so the discussion stays there.
    def decide!(period, decision:, draft_id:, note:)
      event = { "approve" => "approve", "request_changes" => "request_changes" }[decision.to_s]
      raise PayrollSubmissionPeriod::TransitionError, "Choose approve or request a change" unless event

      note = note.to_s.strip
      raise PayrollSubmissionPeriod::TransitionError, "Describe the change you need" if event == "request_changes" && note.blank?
      raise PayrollSubmissionPeriod::TransitionError, "Keep the note under 5,000 characters" if note.length > 5000

      locked(period) do
        draft = period.current_draft
        raise ActiveRecord::RecordNotFound, "Draft not found" unless draft && draft.id == draft_id.to_s.to_i

        target = PayrollSubmissionPeriod::EVENTS.fetch(event)[:to]
        last = period.status_events.last
        if period.status == target && last&.payroll_submission_draft_id == draft.id && last.actor_id == @actor.id
          next draft
        end

        period.transition!(event, actor: @actor, draft: draft, note: note)
        post_message_locked!(period, note) if note.present?
        audit!(period, "payroll_submission_periods##{event}", draft_id: draft.id, draft_revision: draft.revision, note_present: note.present?)
        PortalNotifications.payroll_period!("payroll_draft_decided", period: period, actor: @actor,
          dedupe: "draft:#{draft.id}:#{event}:#{period.status_events.last.id}", metadata: { draft_id: draft.id, decision: event })
        draft
      end
    end

    # Staff upload draft paycheck and direct-deposit PDFs. Posted drafts are
    # shared with the client; a saved draft stays staff-only until posted.
    def create_draft!(entry, params:)
      key = params[:idempotency_key].presence&.to_s
      raise FileSet::Invalid, { "idempotency_key" => [ "is too long" ] } if key && key.length > 128

      if key && entry.record && (existing = entry.record.drafts.find_by(created_by_id: @actor.id, idempotency_key: key))
        return existing
      end

      incoming = []
      incoming << [ "paycheck", params[:paycheck_pdf] ] if params[:paycheck_pdf].present?
      incoming << [ "direct_deposit", params[:direct_deposit_pdf] ] if params[:direct_deposit_pdf].present?
      raise FileSet::Invalid, { "files" => [ "Attach the draft paychecks, the direct deposits, or both" ] } if incoming.empty?

      note = params[:note].to_s.strip.presence
      raise FileSet::Invalid, { "note" => [ "Keep the note under 5,000 characters" ] } if note && note.length > 5000

      post = ActiveModel::Type::Boolean.new.cast(params.fetch(:post, true))
      files = FileSet.new(company_id: @company.id, files: incoming).prepare!.upload!
      draft = nil
      created = false
      PayrollSubmissionPeriod.transaction do
        period = @catalog.materialize!(entry)
        period.lock!
        if key && (draft = period.drafts.find_by(created_by_id: @actor.id, idempotency_key: key))
          raise ActiveRecord::Rollback
        end
        raise PayrollSubmissionPeriod::TransitionError, "This period is paid, so a new draft cannot be posted" if period.status == "paid"
        if post && !period.can?("post_draft", "staff")
          raise PayrollSubmissionPeriod::TransitionError, "Confirm receipt of the latest files before posting a draft"
        end

        revision = (period.drafts.maximum(:revision) || 0) + 1
        documents = files.prepared.to_h do |item|
          title = "#{item.role == 'paycheck' ? 'Draft paychecks' : 'Draft direct deposits'} · #{period.label} · draft #{revision}"
          [ item.role, files.create_document!(item, actor: @actor, title: title, category: "payroll_review", visible_to_client: post) ]
        end
        draft = period.drafts.create!(company_id: @company.id, revision: revision, note: note, created_by: @actor,
          paycheck_document: documents["paycheck"], direct_deposit_document: documents["direct_deposit"],
          idempotency_key: key, posted_at: (Time.current if post), posted_by: (@actor if post))
        if post
          publish!(period, draft)
        else
          audit!(period, "payroll_submission_drafts#create", draft_id: draft.id, draft_revision: draft.revision)
        end
        created = true
      end
      files.discard! unless created
      draft
    rescue StandardError
      files&.discard!
      raise
    end

    def post_draft!(period, draft_id:)
      locked(period) do
        draft = period.drafts.find_by(id: draft_id.to_s.to_i)
        raise ActiveRecord::RecordNotFound, "Draft not found" unless draft
        next draft if draft.posted?
        raise Conflict, "A newer draft exists. Post the latest draft instead." if draft != period.drafts.first

        draft.documents.each { |document| document.update!(visible_to_client: true) }
        draft.update!(posted_at: Time.current, posted_by: @actor)
        publish!(period, draft)
        draft
      end
    end

    # A question or answer about this period, in its own conversation.
    def post_message!(entry, body:, idempotency_key:)
      body = body.to_s.strip
      raise PayrollSubmissionPeriod::TransitionError, "Write a message first" if body.blank?
      raise PayrollSubmissionPeriod::TransitionError, "Keep messages under 5,000 characters" if body.length > 5000

      message = nil
      replayed = false
      PayrollSubmissionPeriod.transaction do
        period = @catalog.materialize!(entry)
        period.lock!
        thread = period.client_portal_thread
        key = idempotency_key.presence&.to_s&.first(128)
        if thread && key && (message = thread.messages.find_by(author_id: @actor.id, idempotency_key: key))
          raise Conflict, "This retry key was used for a different message" unless message.body == body

          replayed = true
          next
        end
        message = create_message!(period, body, key)
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

    def publish!(period, draft)
      period.transition!("post_draft", actor: @actor, draft: draft)
      audit!(period, "payroll_submission_drafts#post", draft_id: draft.id, draft_revision: draft.revision,
        document_ids: draft.documents.map(&:id))
      PortalNotifications.payroll_period!("payroll_draft_posted", period: period, actor: @actor,
        dedupe: "draft:#{draft.id}", metadata: { draft_id: draft.id, revision: draft.revision })
    end

    def post_message_locked!(period, body)
      create_message!(period, body, nil)
    end

    def create_message!(period, body, key)
      thread = ensure_thread!(period)
      message = ClientPortalMessage.create!(client_portal_thread: thread, company_id: period.company_id,
        author: @actor, body: body, idempotency_key: key)
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
