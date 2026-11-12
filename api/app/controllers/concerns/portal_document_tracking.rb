# frozen_string_literal: true

module PortalDocumentTracking
  extend ActiveSupport::Concern
  include PortalAccessTracking
  include BoundedListPagination

  def opened
    @document.with_lock do
      @document.read_receipts.find_or_initialize_by(user: current_user).update!(opened_at: Time.current)
      recent = PortalActivity.feed(@document).where(user_id: current_user.id, action: "portal_documents#opened").where("created_at > ?", 30.seconds.ago)
      audit_portal_document!("portal_documents#opened") unless recent.exists?
    end
    skip_default_audit_log!
    head :no_content
  end

  def activity
    portal_activity_response(@document)
  end

  private

  def audit_portal_document!(action)
    PortalActivity.record!(user: current_user, record: @document, action: action,
      metadata: PortalActivity.document_metadata(@document),
      ip_address: request.remote_ip, user_agent: request.user_agent,
      event_category: "document_access")
  end
end
