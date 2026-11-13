# frozen_string_literal: true

module TestWorkspace
  module PortalAccess
    def self.deactivate_closed!(company)
      User.active.where(practice_company_id: company.id).find_each { |user| deactivate_if_closed!(user) }
    end

    def self.deactivate_if_closed!(user)
      return if user.practice_portal_open?

      user.with_lock do
        return unless user.active? && !user.practice_portal_open?

        user.update!(active: false)
        AuditLog.record!(user: nil, organization_id: user.organization_id, company_id: user.practice_company_id,
          action: "test_workspace#portal_access_deactivated", record_type: "users", record_id: user.id,
          metadata: { reason: "practice_copy_unavailable_or_access_revoked" }, event_category: "security")
      end
    end
  end
end
