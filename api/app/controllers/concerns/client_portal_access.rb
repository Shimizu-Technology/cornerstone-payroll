# frozen_string_literal: true

# The client namespace is for client-role users only. Staff work through the
# admin namespace, so their edits are validated and audited as staff actions
# (ROLE_PERMISSION_MATRIX: "staff users do not enter the client namespace").
#
# A client viewer (User#client_viewer?) is read-only: every write in the
# client namespace is refused here, in one place, whatever the controller.
# Only read receipts (opening a document, reading a thread) still write.
# Notification settings (/api/v1/notification_settings) stay open to viewers
# by design: they are the viewer's own alert preferences, not a company
# change, and that route is outside the client namespace.
module ClientPortalAccess
  extend ActiveSupport::Concern

  VIEW_ONLY = "Your access is view-only. Ask your account manager for changes."
  VIEWER_WRITES = %w[api/v1/client/documents#opened api/v1/client/portal_threads#mark_read].freeze

  included do
    before_action :refuse_client_viewer_write!
  end

  private

  def refuse_client_viewer_write!
    return unless current_user&.client_viewer?
    return if request.get? || request.head? || VIEWER_WRITES.include?("#{controller_path}##{action_name}")

    render json: { error: VIEW_ONLY, code: "client_view_only" }, status: :forbidden
  end

  def require_client_portal_access!
    return if current_user&.client?

    render json: { error: "Client portal access required" }, status: :forbidden
  end
end
