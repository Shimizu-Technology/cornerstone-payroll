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

    Target = Struct.new(:user, :email, :foreign_suppressed) do
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
          if delivery.user_id
            listed = listed_user?(event.company_id, delivery.user_id) || listed_email?(event.company_id, delivery.user&.email)
            return "recipient_removed" unless listed
          else
            return "recipient_removed" unless listed_email?(event.company_id, delivery.recipient_email)

            account_users = account_users_for_email(delivery.recipient_email)
            if account_users.any?
              return nil if account_users.any? { |user| eligible_user?(user, event) }

              same_org = account_users.any? { |user| user.organization_id == event.organization_id }
              return same_org ? "access_revoked" : "foreign_account_suppressed"
            end
          end
        end
        return nil unless delivery.user_id

        eligible_user?(delivery.user, event) ? nil : "access_revoked"
      end

      def account_users_for_email(email)
        PortalNotificationRecipient.matching_users_for_email(email)
      end

      def eligible_account_user_for_email(email, event)
        account_users_for_email(email).find { |user| eligible_user?(user, event) }
      end

      def subject_available?(event)
        subject = event.subject
        return payroll_review_publication_actionable?(event) if event.event_type == "payroll_review_published"

        employee_submission = event.event_type == "employee_change_submitted" && subject.is_a?(EmployeeChangeRequest) &&
          subject.requested_by_link_id.present?
        return false if employee_submission && subject.cancelled?

        if event.event_type == "employee_contact_confirmation_requested" && subject.is_a?(EmployeeContactChangeToConfirm) &&
            subject.change_kind == "delivery_consent"
          return false unless CompanyFeatures.for(event.company).employee_portal_feature?(:delivery_consent)
        elsif employee_submission || %w[address_approvals contact_changes employee_address_decisions].include?(event.category) ||
            event.event_type == "employee_contact_confirmation_requested"
          return false unless CompanyFeatures.for(event.company).employee_portal_feature?(:profile_requests)
        end
        if event.event_type == "employee_contact_confirmation_requested" && subject.is_a?(EmployeeContactChangeToConfirm)
          return false if subject.after_values.key?("emergency_contacts")
        end
        if event.category == "address_approvals"
          return subject.is_a?(EmployeeChangeRequest) && subject.company_id == event.company_id &&
            subject.pending? && subject.profile_address?
        end

        case subject
        when EmployeeDocumentNotice
          event.event_type == "tax_form_paper_required" && subject.company_id == event.company_id &&
            subject.paper_due_on.present? && subject.paper_mailed_on.nil? &&
            CompanyFeatures.for(event.company).employee_portal_feature?(:tax_forms)
        when ClientDocument then !subject.archived? && (event.audience == "staff" || subject.visible_to_client?)
        when ClientPortalThread, EmployeeChangeRequest, EmployeeContactChangeToConfirm, PayrollSubmissionPeriod, PayPeriod then subject.company_id == event.company_id
        else false
        end
      end

      private

      def payroll_review_publication_actionable?(event)
        period = event.subject
        return false unless period.is_a?(PayPeriod) && period.company_id == event.company_id
        return false unless period.approved? && period.correction_status != "voided"

        company = Company.find_by(id: event.company_id)
        return false unless company&.client_payroll_approval_required?

        package = resolve_review_package(event, period)
        package.present? && package.published_at.present? && package.superseded_at.nil? &&
          package.pending? && package.changes_requested_at.nil?
      end

      def resolve_review_package(event, period)
        package_id = event.metadata["review_package_id"] ||
          event.dedupe_key.to_s[/\Apayroll_review_published:(\d+)\z/, 1]
        if package_id.present?
          PayrollReviewPackage.find_by(id: package_id, company_id: event.company_id, pay_period_id: period.id)
        elsif event.metadata["revision"].present?
          PayrollReviewPackage.find_by(company_id: event.company_id, pay_period_id: period.id, revision: event.metadata["revision"])
        end
      end

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
        users = []
        seen_user_ids = []
        taken_canonicals = []
        User.where(id: listed.users.select(:user_id)).order(:id).to_a.each do |user|
          next unless eligible_user?(user, event)

          canonical = PortalNotificationRecipient.canonical_email(user.email)
          next if canonical.present? && taken_canonicals.include?(canonical)

          users << user
          seen_user_ids << user.id
          taken_canonicals << canonical if canonical.present?
        end
        extra_targets = []

        listed.extra_emails.order(:email).pluck(:email).each do |email|
          normalized = PortalNotificationRecipient.normalize_email(email)
          canonical = PortalNotificationRecipient.canonical_email(normalized)
          next if normalized.blank? || canonical.blank? || taken_canonicals.include?(canonical)

          account_users = account_users_for_email(normalized)
          if account_users.any?
            eligible = account_users.find { |user| eligible_user?(user, event) }
            if eligible && !seen_user_ids.include?(eligible.id)
              users << eligible
              seen_user_ids << eligible.id
              taken_canonicals << canonical
            elsif account_users.none? { |user| user.organization_id == event.organization_id }
              # Foreign-organization account: keep internal suppression while
              # preserving tenant-visible counts/statuses as if unregistered.
              extra_targets << Target.new(nil, normalized, true)
              taken_canonicals << canonical
            end
          else
            extra_targets << Target.new(nil, normalized, false)
            taken_canonicals << canonical
          end
        end

        users.map { |user| Target.new(user, nil, false) } + extra_targets
      end

      def client_targets(event)
        candidates = if event.category == "employee_change_decisions"
          # Change request history is requester-only in the client API.
          User.where(id: event.subject.requested_by_id).to_a
        else
          assigned = CompanyAssignment.active_access.where(company_id: event.company_id).select(:user_id)
          User.active.client.where(organization_id: event.organization_id, id: assigned).order(:id).to_a
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
          return false unless staff_can_view_company?(user, company)

          if event.event_type == "employee_contact_confirmation_requested"
            StaffRolePolicy.allowed?(user, :payroll_operations, company: company)
          else
            event.category != "employee_changes" || StaffRolePolicy.allowed?(user, :manage_client_configuration, company: company)
          end
        else
          user.client? && user.payroll_access_allowed? && user.organization_id == company.organization_id &&
            user.can_access_company?(company.id) &&
            (!event.client_managers_only? || !user.client_viewer?) &&
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
        company&.active? && (company.live_payroll? || company.demo?) && company.organization&.active?
      end

      def listed_user?(company_id, user_id)
        PortalNotificationRecipient.exists?(company_id: company_id, user_id: user_id)
      end

      def listed_email?(company_id, email)
        canonical = PortalNotificationRecipient.canonical_email(email)
        return false if canonical.blank?

        PortalNotificationRecipient.where(company_id: company_id).extra_emails.pluck(:email).any? do |listed|
          PortalNotificationRecipient.canonical_email(listed) == canonical
        end
      end
    end
  end
end
