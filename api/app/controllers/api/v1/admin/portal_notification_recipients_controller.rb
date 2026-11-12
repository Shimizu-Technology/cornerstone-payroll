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
          ineligible = false
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :manage_client_administration)
            eligible_ids = PortalNotifications::Recipients.eligible_staff_for(current_company).map(&:id)
            ineligible = (user_ids.uniq - eligible_ids).any?
            raise ActiveRecord::Rollback if ineligible

            changes = replace_recipients!(user_ids.uniq, emails)
            if changes.values.any?(&:present?)
              AuditLog.record!(user: current_user, company_id: current_company.id,
                action: "portal_notification_recipients#update", record_type: "companies", record_id: current_company.id,
                subject_name: current_company.name,
                metadata: changes.merge(recipient_count: PortalNotificationRecipient.where(company_id: current_company.id).count))
            end
          end
          return render_invalid("Only active staff who can view this client can receive its alerts") if ineligible

          render json: { data: payload }
        end

        private

        def render_invalid(message)
          render json: { error: message }, status: :unprocessable_entity
        end

        def replace_recipients!(user_ids, emails)
          scope = PortalNotificationRecipient.where(company_id: current_company.id)
          before_users = scope.users.pluck(:user_id)
          before_emails = scope.extra_emails.pluck(:email)
          scope.users.where.not(user_id: user_ids).delete_all
          scope.extra_emails.where.not(email: emails).delete_all
          (user_ids - before_users).each do |user_id|
            PortalNotificationRecipient.create!(company_id: current_company.id, user_id: user_id, added_by: current_user)
          end
          (emails - before_emails).each do |email|
            PortalNotificationRecipient.create!(company_id: current_company.id, email: email, added_by: current_user)
          end
          names = User.where(id: (user_ids + before_users).uniq).pluck(:id, :name).to_h
          {
            added_users: (user_ids - before_users).map { |id| { id: id, name: names[id] } },
            removed_users: (before_users - user_ids).map { |id| { id: id, name: names[id] } },
            added_emails: emails - before_emails,
            removed_emails: before_emails - emails
          }
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
