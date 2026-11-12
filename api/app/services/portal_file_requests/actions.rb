# frozen_string_literal: true

require "digest"

module PortalFileRequests
  # Request, respond, accept, ask again and withdraw. Each step is one
  # transaction: the request's state, its typed message, the audit entry and
  # the notification are saved together or not at all.
  #
  # Locks are always taken in the same order (pay period, conversation,
  # request, files), so these steps cannot deadlock with ordinary messages.
  class Actions
    class Conflict < StandardError; end

    class Invalid < StandardError
      attr_reader :details

      def initialize(details)
        @details = details
        super(details.values.flatten.first)
      end
    end

    def initialize(company:, actor:, request_context: {})
      @company = company
      @actor = actor
      @request_context = request_context.slice(:ip_address, :user_agent)
    end

    # Staff ask for a file. With a pay period the request goes in that
    # period's conversation; otherwise in the chosen one, or a new one.
    def create!(params)
      attrs = request_attributes(params)
      key = idempotency_key(params)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(attrs.values_at(:title, :category, :employee_id, :period_ref, :due_on_text, :body, :thread_id)))
      request = nil
      replayed = false
      PortalFileRequest.transaction do
        # Serializes this person's retries, including simultaneous ones.
        User.lock.find(@actor.id)
        if key && (request = PortalFileRequest.find_by(company_id: @company.id, requested_by_id: @actor.id, idempotency_key: key))
          raise Conflict, "This retry key was used for a different request" unless request.request_fingerprint == fingerprint

          replayed = true
          next
        end

        period = attrs[:period_entry] && catalog.materialize!(attrs[:period_entry])
        period&.lock!
        thread = conversation_for!(period, attrs)
        thread.lock!
        request = PortalFileRequest.create!(
          company: @company, client_portal_thread: thread, requested_by: @actor, requested_by_name_snapshot: @actor.name,
          title: attrs[:title], category: attrs[:category], employee: attrs[:employee], payroll_submission_period: period,
          due_on: attrs[:due_on], status: "requested", idempotency_key: key, request_fingerprint: fingerprint
        )
        message = step_message!(request, kind: "file_request", body: attrs[:body])
        request.update!(request_message: message)
        audit!(message, "portal_file_requests#create", request)
        PortalNotifications.file_request_step!("file_requested", request: request, message: message)
      end
      broadcast(request) unless replayed
      [ request, replayed ]
    end

    # The client answers with one or more files and an optional note. A
    # second answer before review replaces the one staff will review.
    def respond!(request, params)
      body = message_body(params[:body])
      documents = PortalMessages::Attachments.resolve!(company_id: @company.id, user: @actor,
        ids: PortalMessages::Attachments.requested_ids(params))
      raise Invalid, { "files" => [ "Attach the requested file" ] } if documents.empty?

      step!(request, params, kind: "file_response", body: body, documents: documents) do |locked, message|
        raise Conflict, "This request is #{locked.status_label.downcase}, so it no longer takes files" unless locked.outstanding?

        locked.update!(status: "responded", last_response_message: message, responded_by: @actor, responded_at: Time.current)
        [ "portal_file_requests#respond", "file_request_responded" ]
      end
    end

    # Staff accept the exact answer they reviewed.
    def accept!(request, params)
      body = message_body(params[:body])
      step!(request, params, kind: "file_request_accepted", body: body) do |locked, _message|
        require_reviewed_response!(locked, params)
        locked.update!(status: "accepted", resolved_by: @actor, resolved_at: Time.current)
        [ "portal_file_requests#accept", "file_request_reviewed" ]
      end
    end

    # Staff say what is still wrong; the request waits for a new file.
    def ask_again!(request, params)
      body = message_body(params[:body])
      raise Invalid, { "body" => [ "Say what is still needed" ] } if body.blank?

      step!(request, params, kind: "file_request_asked_again", body: body) do |locked, _message|
        require_reviewed_response!(locked, params)
        locked.update!(status: "requested")
        [ "portal_file_requests#ask_again", "file_request_reviewed" ]
      end
    end

    # The file is no longer needed, so the request stops blocking anything.
    def withdraw!(request, params)
      body = message_body(params[:body])
      step!(request, params, kind: "file_request_withdrawn", body: body) do |locked, _message|
        raise Conflict, "This request is already #{locked.status_label.downcase}" unless locked.outstanding?

        locked.update!(status: "withdrawn", resolved_by: @actor, resolved_at: Time.current)
        [ "portal_file_requests#withdraw", "file_request_reviewed" ]
      end
    end

    private

    # Locks conversation then request, replays a retried step, and otherwise
    # saves the step's message before the block updates the request.
    def step!(request, params, kind:, body:, documents: [])
      key = idempotency_key(params)
      message = nil
      replayed = false
      PortalFileRequest.transaction do
        request.client_portal_thread.lock!
        request.lock!
        if key && (message = request.client_portal_thread.messages.find_by(author_id: @actor.id, idempotency_key: key))
          unless message.portal_file_request_id == request.id && message.kind == kind && message.body.to_s == body.to_s &&
              message.attachment_ids == documents.map(&:id)
            raise Conflict, "This retry key was used for a different message"
          end

          replayed = true
          next
        end

        message = step_message!(request, kind: kind, body: body, documents: documents, key: key)
        action, event_type = yield(request, message)
        audit!(message, action, request)
        PortalNotifications.file_request_step!(event_type, request: request, message: message)
      end
      broadcast(request) unless replayed
      [ request.reload, message, replayed ]
    end

    # Staff review a specific answer. If the client sent another file in
    # the meantime, they must look at that one first.
    def require_reviewed_response!(request, params)
      raise Conflict, "This request is already #{request.status_label.downcase}" unless request.outstanding?
      raise Conflict, "Nothing has been sent for this request yet" unless request.status == "responded"

      reviewed = Integer(params[:response_message_id].to_s, 10)
      return if reviewed == request.last_response_message_id

      raise Conflict, "The client sent a newer file. Review it first."
    rescue ArgumentError
      raise Invalid, { "response_message_id" => [ "Choose the file you reviewed" ] }
    end

    def step_message!(request, kind:, body:, documents: [], key: nil)
      ClientPortalMessage.create!(client_portal_thread: request.client_portal_thread, company: @company, author: @actor,
        kind: kind, file_request: request, body: body.presence, attach_documents: documents, idempotency_key: key)
    end

    def conversation_for!(period, attrs)
      return period_thread!(period) if period
      return attrs[:thread] if attrs[:thread]

      thread = ClientPortalThread.create!(company: @company, created_by: @actor, subject: "File request: #{attrs[:title]}".first(200))
      PortalActivity.record!(user: @actor, record: thread, action: "client_portal_threads#create",
        metadata: { subject: thread.subject }, **@request_context)
      thread
    end

    def period_thread!(period)
      return period.client_portal_thread if period.client_portal_thread

      thread = ClientPortalThread.create!(company: @company, created_by: @actor, subject: "Payroll #{period.label}")
      period.update!(client_portal_thread: thread)
      PortalActivity.record!(user: @actor, record: thread, action: "client_portal_threads#create",
        metadata: { subject: thread.subject, payroll_submission_period_id: period.id }, **@request_context)
      thread
    end

    def request_attributes(params)
      errors = {}
      title = params[:title].to_s.strip.squeeze(" ")
      errors["title"] = [ "Say which file you need" ] if title.blank?
      errors["title"] = [ "Keep the file name under 200 characters" ] if title.length > 200
      category = params[:category].presence || "payroll_source"
      errors["category"] = [ "Choose a file type" ] unless ClientDocument::CATEGORIES.include?(category)
      due_on = parse_date(params[:due_on], errors)
      body = message_body(params[:body])
      employee = find_in_company(Employee, params[:employee_id], "Employee not found")
      thread = find_in_company(ClientPortalThread, params[:thread_id], "Conversation not found")
      period_ref = params[:payroll_submission_period_ref].presence&.to_s
      period_entry = period_ref && catalog.resolve(period_ref)
      raise ActiveRecord::RecordNotFound, "Pay period not found" if period_ref && !period_entry
      raise Invalid, errors if errors.any?

      { title: title, category: category, due_on: due_on, due_on_text: due_on&.iso8601, body: body,
        employee: employee, employee_id: employee&.id, thread: thread, thread_id: thread&.id,
        period_entry: period_entry, period_ref: period_entry && "#{period_entry.start_date}_#{period_entry.end_date}" }
    end

    def parse_date(value, errors)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      errors["due_on"] = [ "Enter a valid date" ]
      nil
    end

    def message_body(value)
      body = value.to_s.strip
      raise Invalid, { "body" => [ "Keep messages under 5,000 characters" ] } if body.length > 5000

      body.presence
    end

    def idempotency_key(params)
      key = params[:idempotency_key].presence&.to_s
      raise Invalid, { "idempotency_key" => [ "is too long" ] } if key && key.length > 128

      key
    end

    def find_in_company(model, id, message)
      return nil if id.blank?

      model.find_by(id: id.to_s.to_i, company_id: @company.id) || raise(ActiveRecord::RecordNotFound, message)
    end

    def catalog
      @catalog ||= PayrollSubmissions::Catalog.new(company: @company)
    end

    def audit!(message, action, request)
      PortalActivity.record!(user: @actor, record: message, action: action,
        metadata: PortalActivity.message_metadata(message).merge(
          file_request_id: request.id, file_request_title: request.title, file_request_status: request.status,
          employee_id: request.employee_id, payroll_submission_period_id: request.payroll_submission_period_id
        ).compact, **@request_context)
    end

    def broadcast(request)
      ClientPortalThreadChannel.broadcast_thread(request.client_portal_thread, event: "message_created")
    end
  end
end
