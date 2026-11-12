# frozen_string_literal: true

module ClientPortalThreadActions
  extend ActiveSupport::Concern
  include ExplicitCompanyAccess
  include BoundedListPagination
  include PortalAccessTracking

  included do
    before_action :set_portal_thread, only: [ :show, :update, :mark_read, :activity ]
  end

  def index
    threads = ClientPortalThread.where(company_id: current_company_id)
                                .includes(:created_by, :resolved_by, messages: [ :author, { client_document: [ :employee, :uploaded_by ] } ])
                                .recent_first
    threads = threads.where(status: params[:status]) if params[:status].present?
    threads = bounded_page(threads)
    portal_serializer.preload_reads(threads)

    render json: {
      data: threads.map { |thread| portal_serializer.thread(thread) },
      meta: bounded_page_meta(threads).merge(unread_count: ClientPortalThread.unread_count_for(current_user, company_id: current_company_id, status: params[:status]))
    }
  end

  def unread_count
    render json: { data: { unread_count: ClientPortalThread.unread_count_for(current_user, company_id: current_company_id) } }
  end

  def show
    render json: { data: portal_serializer.thread(@thread, include_messages: true) }
  end

  def create
    skip_default_audit_log!
    created_thread = nil
    initial_message = nil
    replayed = false
    key = params[:idempotency_key].presence
    request_payload = { subject: params[:subject].presence || default_thread_subject, body: params[:body].to_s, document_id: params[:document_id].presence&.to_i }

    # Serialize per author across conversations, including simultaneous retries.
    current_user.with_lock do
      created_thread = ClientPortalThread.find_by(company_id: current_company_id, created_by_id: current_user.id, idempotency_key: key) if key
      if created_thread
        unless created_thread.creation_payload == request_payload.stringify_keys
          return render json: { error: "This retry key was used for a different conversation" }, status: :conflict
        end
        replayed = true
        next
      end
      created_thread = ClientPortalThread.create!(
        company_id: current_company_id,
        created_by: current_user, idempotency_key: key, creation_payload: request_payload,
        subject: params[:subject].presence || default_thread_subject
      )
      initial_message = create_message_for_thread!(created_thread) if params[:body].present? || params[:document_id].present?
      record_audit!("client_portal_threads#create", created_thread, { subject: created_thread.subject })
      if initial_message
        record_audit!("client_portal_messages#create", initial_message, PortalActivity.message_metadata(initial_message))
        PortalNotifications.message_created!(initial_message)
      end
    end

    created_thread.reload if initial_message
    ClientPortalThreadChannel.broadcast_thread(created_thread, event: "thread_created") unless replayed

    render json: { data: portal_serializer.thread(created_thread, include_messages: true) }, status: replayed ? :ok : :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
  end

  def update
    attrs = {}
    if params[:status].present?
      attrs[:status] = params[:status]
      if params[:status] == "resolved"
        attrs[:resolved_at] = Time.current
        attrs[:resolved_by] = current_user
      elsif params[:status] == "open"
        attrs[:resolved_at] = nil
        attrs[:resolved_by] = nil
      end
    end
    attrs[:subject] = params[:subject] if params[:subject].present?

    @thread.with_lock do
      @thread.update!(attrs)
      action = case attrs[:status]
      when "resolved" then "client_portal_threads#resolved"
      when "open" then "client_portal_threads#reopened"
      else "client_portal_threads#update"
      end
      record_audit!(action, @thread, attrs.slice(:status, :subject).merge(subject: @thread.subject))
    end
    ClientPortalThreadChannel.broadcast_thread(@thread, event: "thread_updated")

    render json: { data: portal_serializer.thread(@thread, include_messages: true) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
  end

  def mark_read
    skip_default_audit_log!
    ids = Array(params[:displayed_message_ids]).map { |id| Integer(id, exception: false) }
    unless params[:foreground] == true && ids.all? &&
        PortalDisplayReceipt.verify(token: params[:display_token], thread: @thread, user: current_user, ids: ids)
      return render json: { error: "A foreground displayed message range is required" }, status: :unprocessable_entity
    end

    @thread.with_lock do
      metadata = { subject: @thread.subject, first_message_id: ids.min, last_message_id: ids.max, displayed_message_ids: ids.sort }
      recent = PortalActivity.feed(@thread).where(user_id: current_user.id, action: "client_portal_threads#opened")
        .where("created_at > ?", 30.seconds.ago).where("metadata->'displayed_message_ids' = ?::jsonb", ids.sort.to_json)
      record_audit!("client_portal_threads#opened", @thread, metadata) unless recent.exists?
      if @thread.mark_read_for!(current_user, displayed_message_ids: ids)
        record_audit!("client_portal_threads#mark_read", @thread, metadata)
      end
    end
    render json: { data: portal_serializer.thread(@thread) }
  end

  def activity
    portal_activity_response(@thread)
  end

  private

  def set_portal_thread
    @thread = ClientPortalThread.find_by!(id: params[:id], company_id: current_company_id)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Thread not found" }, status: :not_found
  end

  def create_message_for_thread!(target_thread)
    document = find_message_document
    ClientPortalMessage.create!(
      client_portal_thread: target_thread,
      company_id: current_company_id,
      author: current_user,
      body: params[:body],
      client_document: document
    )
  end

  def find_message_document
    return nil if params[:document_id].blank?

    ClientDocument.client_visible.find_by!(id: params[:document_id], company_id: current_company_id)
  rescue ActiveRecord::RecordNotFound
    raise ActiveRecord::RecordInvalid.new(ClientPortalMessage.new.tap { |message| message.errors.add(:client_document, "not found") })
  end

  def portal_serializer
    @portal_serializer ||= ClientPortalThreadSerializer.new(current_user: current_user)
  end

  def default_thread_subject
    "Portal message"
  end

  def record_audit!(action, record, metadata)
    PortalActivity.record!(user: current_user, record: record, action: action, metadata: metadata,
      ip_address: request.remote_ip, user_agent: request.user_agent)
  end
end
