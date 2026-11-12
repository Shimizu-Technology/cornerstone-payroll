# frozen_string_literal: true

# Shared by the client and staff namespaces. Every lookup is scoped to the
# request's company; a period ref is a saved id or dates the catalog offers.
module PayrollSubmissionPeriodActions
  extend ActiveSupport::Concern
  include ExplicitCompanyAccess
  include BoundedListPagination

  STAFF_ONLY_ACTIVITY = %w[payroll_submission_drafts#create].freeze

  included do
    before_action :set_period_entry, except: [ :index ]
    rescue_from PayrollSubmissions::FileSet::Invalid, PayrollSubmissions::ChangeRows::Invalid do |error|
      render json: { error: error.message, details: error.details }, status: :unprocessable_entity
    end
    rescue_from PayrollSubmissionPeriod::TransitionError, PayrollSubmissions::CreateRevision::Closed do |error|
      render json: { error: error.message }, status: :unprocessable_entity
    end
    rescue_from PayrollSubmissions::CreateRevision::Conflict, PayrollSubmissions::Actions::Conflict do |error|
      render json: { error: error.message }, status: :conflict
    end
    rescue_from ActiveRecord::RecordInvalid do |error|
      render json: { error: "Please check the details", details: error.record.errors.messages }, status: :unprocessable_entity
    end
    rescue_from R2StorageService::UploadError do |error|
      render json: { error: error.message }, status: :unprocessable_entity
    end
  end

  def index
    render json: { data: payroll_catalog.entries.map { |entry| payroll_serializer.summary(entry) },
      meta: { derives_from_schedule: payroll_catalog.derives_from_schedule? } }
  end

  def show
    render json: { data: payroll_serializer.detail(@entry) }
  end

  def messages
    skip_default_audit_log!
    message, replayed = payroll_actions.post_message!(@entry, body: params[:body], idempotency_key: params[:idempotency_key])
    render json: { data: ClientPortalThreadSerializer.new(current_user: current_user).message(message), thread_id: message.client_portal_thread_id },
      status: replayed ? :ok : :created
  end

  def activity
    return render(json: { data: [], meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 0 } }) unless @entry.record

    feed = PayrollSubmissions::Audit.feed(@entry.record)
    feed = feed.where.not(action: STAFF_ONLY_ACTIVITY) unless current_user.staff_member?
    page = bounded_page(feed)
    render json: { data: page.map { |log| PortalActivity.serialize(log) }, meta: bounded_page_meta(page) }
  end

  private

  def set_period_entry
    @entry = payroll_catalog.resolve(params[:ref])
    render json: { error: "Pay period not found" }, status: :not_found unless @entry
  end

  def saved_period!
    return @entry.record if @entry.record

    raise ActiveRecord::RecordNotFound, "Nothing has been sent for this period yet"
  end

  def payroll_catalog
    @payroll_catalog ||= PayrollSubmissions::Catalog.new(company: Company.find(current_company_id))
  end

  def payroll_serializer
    @payroll_serializer ||= PayrollSubmissions::Serializer.new(current_user: current_user, catalog: payroll_catalog)
  end

  def payroll_actions
    PayrollSubmissions::Actions.new(company: payroll_catalog_company, actor: current_user, catalog: payroll_catalog,
      request_context: payroll_request_context)
  end

  def payroll_catalog_company
    Company.find(current_company_id)
  end

  def payroll_request_context
    { ip_address: request.remote_ip, user_agent: request.user_agent }
  end

  def render_period(status = :ok)
    entry = payroll_catalog.resolve(@entry.record&.id || params[:ref])
    render json: { data: payroll_serializer.detail(entry) }, status: status
  end
end
