# frozen_string_literal: true

module Api
  module V1
    module Admin
      # The selected client's staff-side portal alert recipients. Viewing and
      # changing the list both require client administration for this client.
      class PortalNotificationRecipientsController < BaseController
        WARNING_WINDOW = 30.days

        def show
          render json: { data: payload }
        end

        def update
          user_ids = Array(params[:user_ids]).map { |id| Integer(id, exception: false) }
          emails = Array(params[:emails]).map { |email| PortalNotificationRecipient.normalize_email(email) }.compact.uniq
          return render_invalid("Choose staff members from the list") unless user_ids.all?

          lead_user_id = parse_optional_user_id(params[:lead_user_id])
          backup_user_id = parse_optional_user_id(params[:backup_user_id])
          return render_invalid("Choose staff members from the list") if lead_user_id == :invalid || backup_user_id == :invalid

          invalid = emails.reject { |email| PortalNotificationRecipient.valid_email?(email) }
          return render_invalid("Check these email addresses: #{invalid.join(', ')}") if invalid.any?
          if emails.size > PortalNotificationRecipient::MAX_EXTRA_EMAILS
            return render_invalid("Add up to #{PortalNotificationRecipient::MAX_EXTRA_EMAILS} extra email addresses")
          end

          skip_default_audit_log!
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :manage_client_administration)
            PortalNotifications::RecipientListUpdate.call!(
              company: current_company,
              actor: current_user,
              user_ids: user_ids,
              emails: emails,
              lead_user_id: lead_user_id,
              backup_user_id: backup_user_id
            )
          end

          render json: { data: payload }
        rescue PortalNotifications::RecipientListUpdate::IneligibleRecipient
          render_invalid("Only active staff who can view this client can receive its alerts")
        rescue PortalNotifications::RecipientListUpdate::EmailBelongsToAccount => e
          render_invalid("#{e.message} already has a Cornerstone Payroll account. Tick that person in the list instead, so their own alert settings apply.")
        rescue PortalNotifications::RecipientListUpdate::InvalidTeamRole => e
          render_invalid(e.message)
        end

        private

        def parse_optional_user_id(value)
          return nil if value.nil? || value.to_s.strip.empty?

          Integer(value, exception: false) || :invalid
        end

        def render_invalid(message)
          render json: { error: message }, status: :unprocessable_entity
        end

        def payload
          listed = PortalNotificationRecipient.where(company_id: current_company.id)
          listed_roles = listed.users.pluck(:user_id, :team_role).to_h
          listed_ids = listed_roles.keys
          eligible = PortalNotifications::Recipients.eligible_staff_for(current_company)
          eligible_ids = eligible.map(&:id)
          eligible_emails = eligible.map { |user| PortalNotificationRecipient.normalize_email(user.email) }.compact
          emails = listed.extra_emails.order(:email).pluck(:email)
          active_ids = listed_ids & eligible_ids
          account_emails = emails.any? ? User.where("LOWER(email) IN (?)", emails).pluck(:email).map { |e| PortalNotificationRecipient.normalize_email(e) } : []
          active_extra_count = emails.count { |email| !account_emails.include?(email) || eligible_emails.include?(email) }
          active_count = active_ids.size + active_extra_count
          lead_user_id = active_ids.find { |id| listed_roles[id] == "lead" }
          backup_user_id = active_ids.find { |id| listed_roles[id] == "backup" }
          {
            company_id: current_company.id,
            eligible_users: eligible.map do |user|
              {
                id: user.id,
                name: user.name,
                email: user.email,
                role: user.role,
                selected: listed_roles.key?(user.id),
                team_role: listed_roles[user.id]
              }
            end,
            lead_user_id: lead_user_id,
            backup_user_id: backup_user_id,
            needs_lead: active_ids.any? && lead_user_id.nil?,
            ineligible_listed_users: User.where(id: listed_ids - eligible_ids).order(:name).map { |user| { id: user.id, name: user.name } },
            extra_emails: emails,
            recipient_count: active_count,
            max_extra_emails: PortalNotificationRecipient::MAX_EXTRA_EMAILS,
            unnotified_event_count: PortalNotificationEvent.without_staff_recipients
              .where(company_id: current_company.id).where("occurred_at > ?", WARNING_WINDOW.ago).count,
            email_delivery_enabled: PortalNotifications.delivery_enabled?
          }
        end
      end
    end
  end
end
