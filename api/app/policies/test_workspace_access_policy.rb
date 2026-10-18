# frozen_string_literal: true

class TestWorkspaceAccessPolicy
  ADMIN_ROLES = %w[super_admin org_admin admin].freeze
  GLOBAL_ADMIN_CAPABILITIES = %i[manage_organization manage_platform].freeze
  PROTECTED_CAPABILITIES = %i[manage_client_administration manage_client_configuration manage_source_delegations manage_payroll_go_live_setup manage_organization manage_platform].freeze

  # These POST endpoints only render plain-paper earnings statements. They do
  # not prepare/issue checks, persist artifacts, upload, or dispatch providers.
  # Caller metadata is server controller/action identity, never request params.
  READ_POST_ACTIONS = {
    "api/v1/admin/pay_stubs" => %w[batch_pdf direct_deposit_stubs_pdf]
  }.freeze

  def self.allowed?(user:, company:, request_method:, capability: nil, controller_path: nil, action_name: nil)
    return true unless company&.test_workspace?
    return false unless user&.staff_member?
    return true if ADMIN_ROLES.include?(user.role) && GLOBAL_ADMIN_CAPABILITIES.include?(capability)
    read_request = request_method.in?(%w[GET HEAD]) ||
      (request_method == "POST" && READ_POST_ACTIONS.fetch(controller_path, []).include?(action_name))
    return read_request if company.test_workspace_read_only?
    return true if ADMIN_ROLES.include?(user.role)

    assignment = user.company_assignments.active_access.find_by(company_id: company.id)
    return false unless assignment

    case assignment.workspace_access_level
    when "workspace_admin"
      true
    when "reviewer"
      read_request
    when "operator"
      !PROTECTED_CAPABILITIES.include?(capability)
    else
      false
    end
  end
end
