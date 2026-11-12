# frozen_string_literal: true

# The client namespace is for client-role users only. Staff work through the
# admin namespace, so their edits are validated and audited as staff actions
# (ROLE_PERMISSION_MATRIX: "staff users do not enter the client namespace").
module ClientPortalAccess
  extend ActiveSupport::Concern

  private

  def require_client_portal_access!
    return if current_user&.client?

    render json: { error: "Client portal access required" }, status: :forbidden
  end
end
