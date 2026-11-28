# frozen_string_literal: true

module ClientOperatingProfiles
  # Evaluates the three fail-closed preconditions required before
  # client_portal.employee_lifecycle_mode = "client_managed" can be saved or
  # activated (§4.1, §5.1):
  #   1. Zero pending non-address EmployeeChangeRequest rows
  #   2. No active 24-hour EmployeeIntakePolicy window
  #   3. At least one qualifying staff PortalNotificationRecipient
  class LifecycleModePreflight
    Result = Data.define(
      :pending_non_address_change_requests_count,
      :active_intake_window,
      :qualifying_staff_notification_recipients_count,
      :error_messages
    ) do
      def passed?
        error_messages.empty?
      end

      def blockers_hash
        blockers = {}
        if pending_non_address_change_requests_count.positive?
          blockers["pending_non_address_change_requests_count"] = pending_non_address_change_requests_count
        end
        blockers["active_intake_window"] = true if active_intake_window
        if qualifying_staff_notification_recipients_count.zero?
          blockers["qualifying_staff_notification_recipients_count"] = 0
        end
        blockers
      end
    end

    class << self
      def evaluate(company)
        pending_count = pending_non_address_requests_scope(company).count
        intake_open = EmployeeIntakePolicy.enabled?(company)
        recipient_count = qualifying_staff_recipient_count(company)

        errors = []
        if pending_count.positive?
          noun = pending_count == 1 ? "request" : "requests"
          errors << "Approve or reject #{pending_count} pending employee change #{noun} before switching to Client manages, Cornerstone verifies."
        end
        if intake_open
          errors << "Close the open incomplete-employee entry window before switching to Client-managed mode."
        end
        if recipient_count.zero?
          errors << "Add at least one staff notification recipient for this company before turning on Client-managed mode so verification alerts aren't missed."
        end

        Result.new(
          pending_non_address_change_requests_count: pending_count,
          active_intake_window: intake_open,
          qualifying_staff_notification_recipients_count: recipient_count,
          error_messages: errors
        )
      end

      def summary_for(company, as_of: PayrollBusinessClock.today)
        result = evaluate(company)
        today = as_of.to_date
        active_profile = ClientOperatingProfile.for_date(company.id, today)
        future_scheduled = company.client_operating_profiles
          .where("effective_on > ?", today)
          .where("client_portal_enabled = true")
          .where("options -> 'client_portal' ->> 'employee_lifecycle_mode' = ?", "client_managed")
          .order(effective_on: :asc, version: :desc)
          .first

        status, blockers, scheduled_effective_on =
          if CompanyFeatures.for(company, on: today).client_managed_employee_lifecycle?
            [ "active", {}, nil ]
          elsif active_profile&.client_portal_enabled? &&
              active_profile.option_value("client_portal.employee_lifecycle_mode") == "client_managed" &&
              active_profile.lifecycle_mode_activated_at.nil?
            if active_profile.lifecycle_mode_activation_failed_at.present?
              [ "blocked", active_profile.lifecycle_mode_activation_blockers.to_h, active_profile.effective_on.iso8601 ]
            else
              [ "scheduled", {}, active_profile.effective_on.iso8601 ]
            end
          elsif future_scheduled.present?
            [ "scheduled", {}, future_scheduled.effective_on.iso8601 ]
          else
            [ "inactive", {}, nil ]
          end

        {
          pending_non_address_change_requests_count: result.pending_non_address_change_requests_count,
          active_intake_window: result.active_intake_window,
          qualifying_staff_notification_recipients_count: result.qualifying_staff_notification_recipients_count,
          ready: result.passed?,
          blockers: result.error_messages,
          lifecycle_mode_activation_status: status,
          lifecycle_mode_activation_blockers: blockers,
          scheduled_effective_on: scheduled_effective_on
        }
      end

      def pending_non_address_requests_scope(company)
        company_scope = EmployeeChangeRequest.for_company(company.id)
        company_scope.pending.where.not(id: company_scope.profile_addresses.select(:id))
      end

      def client_managed_active_or_scheduled?(company, as_of: PayrollBusinessClock.today)
        return false if CompanyFeatures::LOCKED_OFF.include?("client_portal.employee_lifecycle_mode")
        return true if CompanyFeatures.for(company, on: as_of).client_managed_employee_lifecycle?

        today = as_of.to_date
        company.client_operating_profiles
          .where(client_portal_enabled: true, lifecycle_mode_activation_failed_at: nil)
          .where("ends_on IS NULL OR ends_on >= ?", today)
          .where("options -> 'client_portal' ->> 'employee_lifecycle_mode' = ?", "client_managed")
          .exists?
      end

      def qualifying_staff_recipient_count(company)
        listed = PortalNotificationRecipient.where(company_id: company.id)
        qualifying_staff_recipient_count_for(
          company,
          user_ids: listed.users.pluck(:user_id),
          emails: listed.extra_emails.pluck(:email)
        )
      end

      def qualifying_staff_recipient_count_for(company, user_ids:, emails:)
        users = User.includes(:organization).where(id: Array(user_ids)).to_a
        qualifying_users = users.select { |user| qualifying_staff_user?(user, company) }
        taken_canonicals = qualifying_users.filter_map { |user| PortalNotificationRecipient.canonical_email(user.email) }.to_set

        normalized_emails = Array(emails).filter_map { |email| PortalNotificationRecipient.normalize_email(email) }
        same_org_accounts = if normalized_emails.any?
          PortalNotificationRecipient.matching_users_for_emails(
            normalized_emails,
            scope: User.includes(:organization).where(organization_id: company.organization_id)
          ).group_by { |user| PortalNotificationRecipient.canonical_email(user.email) }
        else
          {}
        end

        qualifying_extra_count = 0
        normalized_emails.each do |email|
          canonical = PortalNotificationRecipient.canonical_email(email)
          next if canonical.blank? || taken_canonicals.include?(canonical)

          accounts = same_org_accounts[canonical]
          if accounts.present?
            next unless accounts.any? { |user| qualifying_staff_user?(user, company) }
          end

          taken_canonicals << canonical
          qualifying_extra_count += 1
        end

        qualifying_users.size + qualifying_extra_count
      end

      private

      def qualifying_staff_user?(user, company)
        user.payroll_access_allowed? &&
          user.staff_member? &&
          user.organization_id == company.organization_id &&
          StaffRolePolicy.allowed?(user, :staff_workspace) &&
          user.can_access_company?(company.id) &&
          StaffRolePolicy.allowed?(user, :manage_client_configuration, company: company)
      end
    end
  end
end
