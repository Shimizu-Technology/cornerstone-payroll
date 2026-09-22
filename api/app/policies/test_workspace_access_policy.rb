# frozen_string_literal: true

class TestWorkspaceAccessPolicy
  ADMIN_ROLES = %w[super_admin org_admin admin].freeze
  GLOBAL_ADMIN_CAPABILITIES = %i[manage_organization manage_platform].freeze
  PROTECTED_CAPABILITIES = %i[manage_client_configuration manage_organization manage_platform].freeze

  def self.allowed?(user:, company:, request_method:, capability: nil)
    return true unless company&.test_workspace?
    return false unless user&.staff_member?
    return true if ADMIN_ROLES.include?(user.role) && GLOBAL_ADMIN_CAPABILITIES.include?(capability)
    return request_method.in?(%w[GET HEAD]) if company.test_workspace_read_only?
    return true if ADMIN_ROLES.include?(user.role)

    assignment = user.company_assignments.active_access.find_by(company_id: company.id)
    return false unless assignment

    case assignment.workspace_access_level
    when "workspace_admin"
      true
    when "reviewer"
      request_method.in?(%w[GET HEAD])
    when "operator"
      !PROTECTED_CAPABILITIES.include?(capability)
    else
      false
    end
  end
end
