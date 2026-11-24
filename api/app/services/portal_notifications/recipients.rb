# frozen_string_literal: true

module PortalNotifications
  # Who may be alerted about an event.
  #
  # Staff-side alerts go only to the client's configured recipient list: app
  # users an administrator ticked, plus extra addresses. Client-side alerts go
  # to the client's active portal users. Every check is repeated from fresh
  # records before each send or retry, so removal from the list, deactivation
  # or lost company access stops further sends.
  module Recipients
    STAFF_ROLES = %w[super_admin org_admin admin manager accountant].freeze

    Target = Struct.new(:user, :email) do
      def key
        user ? "user:#{user.id}" : "email:#{email}"
      end
    end

    class << self
      # Returns [targets, recipient_status].
      def resolve(event)
        return [ [], "no_recipients" ] unless subject_available?(event) && company_open?(event.company_id)

        targets = case event.audience
        when "staff" then staff_targets(event)
        when "employee" then [ employee_target(event) ].compact
        else client_targets(event)
        end
        [ targets, targets.any? ? "recipients" : "no_recipients" ]
      end

      # Staff users who could be ticked for this client: active, same
      # organization, and able to open its portal work.
      def eligible_staff_for(company)
        User.active.where(organization_id: company.organization_id, role: STAFF_ROLES).order(:name, :id).to_a
          .select { |user| staff_can_view_company?(user, company) }
      end

      # nil when the row may still send; otherwise the skip reason.
      def revocation_reason(delivery)
        event = delivery.event
        return "access_revoked" unless company_open?(event.company_id)

        if event.audience == "employee"
          return employee_target(event)&.email == delivery.recipient_email ? nil : "access_revoked"
        end
        if event.audience == "staff"
          listed = delivery.user_id ? listed_user?(event.company_id, delivery.user_id) : listed_email?(event.company_id, delivery.recipient_email)
          return "recipient_removed" unless listed
        end
        return nil unless delivery.user_id

        eligible_user?(delivery.user, event) ? nil : "access_revoked"
      end

      def subject_available?(event)
        subject = event.subject
        if %w[address_approvals contact_changes employee_address_decisions].include?(event.category)
          return false unless CompanyFeatures.for(event.company).employee_portal_feature?(:profile_requests)
        end
        if event.category == "address_approvals"
          return subject.is_a?(EmployeeChangeRequest) && subject.company_id == event.company_id &&
            subject.pending? && subject.profile_address?
        end

        case subject
        when ClientDocument then !subject.archived? && (event.audience == "staff" || subject.visible_to_client?)
        when ClientPortalThread, EmployeeChangeRequest, EmployeeContactChangeToConfirm, PayrollSubmissionPeriod, PayPeriod then subject.company_id == event.company_id
        else false
        end
      end

      private

      def employee_target(event)
        request = event.subject
        return unless request.is_a?(EmployeeChangeRequest) && request.company_id == event.company_id &&
          request.profile_address? && !request.pending? && Email.employee_portal_url(event.company).present?

        link = EmployeeAccountLink.portal_eligible.find_by(
          id: request.requested_by_link_id, company_id: request.company_id, employee_id: request.employee_id,
          user_id: request.requested_by_id
        )
        return unless link&.user&.payroll_access_allowed?

        employee = link.employee
        return unless employee.email_verified_at? && employee.email.present?

        Target.new(nil, employee.email)
      end

      def staff_targets(event)
        listed = PortalNotificationRecipient.where(company_id: event.company_id)
        users = User.where(id: listed.users.select(:user_id)).order(:id).to_a.select { |user| eligible_user?(user, event) }
        taken = users.map { |user| user.email.to_s.downcase }
        emails = listed.extra_emails.order(:email).pluck(:email).reject { |email| taken.include?(email) }
        users.map { |user| Target.new(user, nil) } + emails.map { |email| Target.new(nil, email) }
      end

      def client_targets(event)
        candidates = if event.category == "employee_change_decisions"
          # Change request history is requester-only in the client API.
          User.where(id: event.subject.requested_by_id).to_a
        else
          assigned = CompanyAssignment.active_access.where(company_id: event.company_id).select(:user_id)
          User.active.client.where(organization_id: event.organization_id)
            .where("users.id IN (?) OR users.company_id = ?", assigned, event.company_id).order(:id).to_a
        end
        candidates.select { |user| eligible_user?(user, event) }.map { |user| Target.new(user, nil) }
      end

      # Never trusts a memoized user or access list.
      def eligible_user?(user, event)
        user = User.includes(:organization).find_by(id: user&.id)
        company = Company.includes(:organization).find_by(id: event.company_id)
        return false unless user && company
        return false if event.actor_id.present? && event.actor_id == user.id

        if event.audience == "staff"
          staff_can_view_company?(user, company) &&
            (event.category != "employee_changes" || StaffRolePolicy.allowed?(user, :manage_client_configuration, company: company))
        else
          user.client? && user.payroll_access_allowed? && user.organization_id == company.organization_id &&
            user.can_access_company?(company.id) &&
            (event.category != "employee_change_decisions" || event.subject.requested_by_id == user.id) &&
            (event.category != "address_approvals" || can_review_address?(event.subject, user)) &&
            (event.category != "contact_changes" || event.subject.changed_by_id != user.id)
        end
      end

      def can_review_address?(request, user)
        !request.same_person_reviewer?(user)
      rescue EmployeeProfileIdentity::LinkCheckUnavailable
        false
      end

      def staff_can_view_company?(user, company)
        user.payroll_access_allowed? && user.staff_member? && user.organization_id == company.organization_id &&
          StaffRolePolicy.allowed?(user, :staff_workspace) && user.can_access_company?(company.id)
      end

      def company_open?(company_id)
        company = Company.includes(:organization).find_by(id: company_id)
        company&.active? && company.live_payroll? && company.organization&.active?
      end

      def listed_user?(company_id, user_id)
        PortalNotificationRecipient.exists?(company_id: company_id, user_id: user_id)
      end

      def listed_email?(company_id, email)
        email.present? && PortalNotificationRecipient.exists?(company_id: company_id, email: email)
      end
    end
  end
end
