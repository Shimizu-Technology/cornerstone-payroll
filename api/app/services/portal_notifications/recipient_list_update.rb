# frozen_string_literal: true

module PortalNotifications
  # Replaces one client's alert recipient list and audits the change. Call it
  # inside the caller's company lock after write access has been revalidated;
  # an ineligible staff member raises and rolls the whole change back.
  class RecipientListUpdate
    class IneligibleRecipient < StandardError; end
    # Extra addresses are for people without an account. An account holder's
    # address must be ticked instead, so their own alert setting applies.
    class EmailBelongsToAccount < StandardError; end

    def self.call!(company:, actor:, user_ids:, emails:)
      new(company: company, actor: actor, user_ids: user_ids.uniq, emails: emails).call!
    end

    def initialize(company:, actor:, user_ids:, emails:)
      @company = company
      @actor = actor
      @user_ids = user_ids
      @emails = emails
    end

    def call!
      eligible_ids = Recipients.eligible_staff_for(company).map(&:id)
      raise IneligibleRecipient if (user_ids - eligible_ids).any?
      account_email = User.where("LOWER(email) IN (?)", emails).pick(:email) if emails.any?
      raise EmailBelongsToAccount, account_email.downcase if account_email

      changes = replace!
      if changes.values.any?(&:present?)
        AuditLog.record!(user: actor, company_id: company.id,
          action: "portal_notification_recipients#update", record_type: "companies", record_id: company.id,
          subject_name: company.name,
          metadata: changes.merge(recipient_count: PortalNotificationRecipient.where(company_id: company.id).count))
      end
      changes
    end

    private

    attr_reader :company, :actor, :user_ids, :emails

    def replace!
      scope = PortalNotificationRecipient.where(company_id: company.id)
      before_users = scope.users.pluck(:user_id)
      before_emails = scope.extra_emails.pluck(:email)
      scope.users.where.not(user_id: user_ids).delete_all
      scope.extra_emails.where.not(email: emails).delete_all
      (user_ids - before_users).each do |user_id|
        PortalNotificationRecipient.create!(company_id: company.id, user_id: user_id, added_by: actor)
      end
      (emails - before_emails).each do |email|
        PortalNotificationRecipient.create!(company_id: company.id, email: email, added_by: actor)
      end
      names = User.where(id: (user_ids + before_users).uniq).pluck(:id, :name).to_h
      {
        added_users: (user_ids - before_users).map { |id| { id: id, name: names[id] } },
        removed_users: (before_users - user_ids).map { |id| { id: id, name: names[id] } },
        added_emails: emails - before_emails,
        removed_emails: before_emails - emails
      }
    end
  end
end
