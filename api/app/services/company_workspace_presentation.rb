# frozen_string_literal: true

# Test-workspace fields as staff and client screens receive them. A demo
# company is contained on the server but must look exactly like a live client,
# so it serializes with the live shape. Organization admins also receive
# company_type, the single place a demo identifies itself.
module CompanyWorkspacePresentation
  LIVE_SHAPE = {
    payroll_environment: "live",
    demo: false,
    test_workspace: false,
    test_workspace_purpose: nil,
    test_workspace_purpose_label: nil,
    test_workspace_expires_at: nil,
    test_workspace_archived_at: nil,
    test_workspace_sealed_at: nil,
    test_workspace_expired: false,
    test_workspace_read_only: false,
    migration_rehearsal_status: nil,
    migration_source_company_id: nil,
    migration_source_company_name: nil,
    migration_source_batch_id: nil,
    migration_rehearsal_completed_at: nil,
    migration_rehearsal_error: nil
  }.freeze

  def self.fields(company, manifest: false)
    payload = if company.demo?
      LIVE_SHAPE.merge(demo: true)
    else
      {
        payroll_environment: company.payroll_environment,
        demo: false,
        test_workspace: company.test_workspace?,
        test_workspace_purpose: company.test_workspace_purpose,
        test_workspace_purpose_label: company.test_workspace_purpose_label,
        test_workspace_expires_at: company.test_workspace_expires_at,
        test_workspace_archived_at: company.test_workspace_archived_at,
        test_workspace_sealed_at: company.test_workspace_sealed_at,
        test_workspace_expired: company.test_workspace_expired?,
        test_workspace_read_only: company.test_workspace_read_only?,
        migration_rehearsal_status: company.migration_rehearsal_status,
        migration_source_company_id: company.migration_source_company_id,
        migration_source_company_name: company.migration_source_company&.name,
        migration_source_batch_id: company.migration_source_batch_id,
        migration_rehearsal_completed_at: company.migration_rehearsal_completed_at,
        migration_rehearsal_error: company.migration_rehearsal_error
      }
    end
    payload[:test_workspace_manifest] = company.demo? ? {} : company.test_workspace_manifest if manifest
    payload
  end

  def self.company_type(company, viewer:)
    return unless viewer&.organization_admin? && viewer.organization_id == company.organization_id

    company.demo? ? "demo" : "client"
  end
end
