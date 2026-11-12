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

          invalid = emails.reject { |email| PortalNotificationRecipient.valid_email?(email) }
          return render_invalid("Check these email addresses: #{invalid.join(', ')}") if invalid.any?
          if emails.size > PortalNotificationRecipient::MAX_EXTRA_EMAILS
            return render_invalid("Add up to #{PortalNotificationRecipient::MAX_EXTRA_EMAILS} extra email addresses")
          end

          skip_default_audit_log!
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :manage_client_administration)
            PortalNotifications::RecipientListUpdate.call!(company: current_company, actor: current_user, user_ids: user_ids, emails: emails)
          end

          render json: { data: payload }
        rescue PortalNotifications::RecipientListUpdate::IneligibleRecipient
          render_invalid("Only active staff who can view this client can receive its alerts")
        rescue PortalNotifications::RecipientListUpdate::EmailBelongsToAccount => e
          render_invalid("#{e.message} already has a Cornerstone Payroll account. Tick that person in the list instead, so their own alert settings apply.")
        end

        private

        def render_invalid(message)
          render json: { error: message }, status: :unprocessable_entity
        end

        def payload
          listed = PortalNotificationRecipient.where(company_id: current_company.id)
          listed_ids = listed.users.pluck(:user_id)
          eligible = PortalNotifications::Recipients.eligible_staff_for(current_company)
          eligible_ids = eligible.map(&:id)
          emails = listed.extra_emails.order(:email).pluck(:email)
          active_count = (listed_ids & eligible_ids).size + emails.size
          {
            company_id: current_company.id,
            eligible_users: eligible.map do |user|
              { id: user.id, name: user.name, email: user.email, role: user.role, selected: listed_ids.include?(user.id) }
            end,
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
