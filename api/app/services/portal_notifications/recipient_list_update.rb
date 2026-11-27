# frozen_string_literal: true

module PortalNotifications
  # Replaces one client's Cornerstone account team (alert recipient list) and
  # audits the change. Call it inside the caller's company lock after write
  # access has been revalidated; an ineligible staff member or invalid team
  # role raises and rolls the whole change back.
  class RecipientListUpdate
    class IneligibleRecipient < StandardError; end
    # Extra addresses are for people without an account. An account holder's
    # address must be ticked instead, so their own alert setting applies.
    class EmailBelongsToAccount < StandardError; end
    class InvalidTeamRole < StandardError; end
    class LastLifecycleRecipientRequired < StandardError; end

    def self.call!(company:, actor:, user_ids:, emails:, lead_user_id: nil, backup_user_id: nil)
      new(
        company: company,
        actor: actor,
        user_ids: user_ids.uniq,
        emails: emails,
        lead_user_id: lead_user_id,
        backup_user_id: backup_user_id
      ).call!
    end

    def initialize(company:, actor:, user_ids:, emails:, lead_user_id: nil, backup_user_id: nil)
      @company = company
      @actor = actor
      @user_ids = user_ids
      @emails = Array(emails)
        .filter_map { |email| PortalNotificationRecipient.normalize_email(email) }
        .uniq { |email| PortalNotificationRecipient.canonical_email(email) }
      @lead_user_id = lead_user_id
      @backup_user_id = backup_user_id
    end

    def call!
      eligible_ids = Recipients.eligible_staff_for(company).map(&:id)
      raise IneligibleRecipient if (user_ids - eligible_ids).any?
      raise IneligibleRecipient if (lead_user_id && !eligible_ids.include?(lead_user_id)) ||
        (backup_user_id && !eligible_ids.include?(backup_user_id))
      if user_ids.any? && lead_user_id.nil?
        raise InvalidTeamRole, "Choose an Account lead when staff are assigned to the account team"
      end
      if backup_user_id && lead_user_id.nil?
        raise InvalidTeamRole, "Choose an Account lead before assigning a Backup"
      end
      if lead_user_id && backup_user_id && lead_user_id == backup_user_id
        raise InvalidTeamRole, "Choose different staff members for Lead and Backup"
      end
      if (lead_user_id && !user_ids.include?(lead_user_id)) || (backup_user_id && !user_ids.include?(backup_user_id))
        raise InvalidTeamRole, "Lead and Backup must be selected on the account team"
      end

      # Check only same-organization accounts on save so the tenant-facing
      # response never acts as an existence oracle for foreign organizations.
      # Foreign-organization accounts are still suppressed internally at enqueue
      # and dispatch by PortalNotifications::Recipients.
      if emails.any?
        same_org_matches = PortalNotificationRecipient.matching_users_for_emails(
          emails, scope: User.where(organization_id: company.organization_id)
        )
        if same_org_matches.any?
          matched_canonicals = same_org_matches.filter_map { |user| PortalNotificationRecipient.canonical_email(user.email) }.to_set
          matched_email = emails.find { |email| matched_canonicals.include?(PortalNotificationRecipient.canonical_email(email)) } ||
            same_org_matches.first.email.downcase
          raise EmailBelongsToAccount, matched_email
        end
      end

      if ClientOperatingProfiles::LifecycleModePreflight.client_managed_active_or_scheduled?(company) &&
          ClientOperatingProfiles::LifecycleModePreflight.qualifying_staff_recipient_count_for(
            company,
            user_ids: user_ids,
            emails: emails
          ).zero?
        raise LastLifecycleRecipientRequired,
              "Keep at least one qualifying staff notification recipient while Client-managed employee lifecycle is active or scheduled."
      end

      changes = replace!
      if changes.values.any?(&:present?)
        AuditLog.record!(user: actor, company_id: company.id,
          action: "portal_notification_recipients#update", record_type: "companies", record_id: company.id,
          subject_name: company.name,
          metadata: changes.merge(
            recipient_count: PortalNotificationRecipient.where(company_id: company.id).count,
            lead_user_id: lead_user_id,
            backup_user_id: backup_user_id
          ).compact)
      end
      changes
    end

    private

    attr_reader :company, :actor, :user_ids, :emails, :lead_user_id, :backup_user_id

    def team_role_for(user_id)
      return "lead" if lead_user_id && user_id == lead_user_id
      return "backup" if backup_user_id && user_id == backup_user_id

      nil
    end

    def replace!
      scope = PortalNotificationRecipient.where(company_id: company.id)
      before_users = scope.users.pluck(:user_id)
      before_emails = scope.extra_emails.pluck(:email)
      before_lead_id = scope.lead.pick(:user_id)
      before_backup_id = scope.backup.pick(:user_id)

      scope.users.where.not(user_id: user_ids).delete_all
      scope.extra_emails.where.not(email: emails).delete_all

      # Clear changed roles before assigning new ones so swapping Lead and
      # Backup between two existing team members never trips the unique index.
      scope.users.where.not(team_role: nil).find_each do |row|
        row.update!(team_role: nil) if row.team_role != team_role_for(row.user_id)
      end

      (user_ids - before_users).each do |user_id|
        PortalNotificationRecipient.create!(
          company_id: company.id, user_id: user_id, team_role: team_role_for(user_id), added_by: actor
        )
      end

      scope.users.where(user_id: [ lead_user_id, backup_user_id ].compact).find_each do |row|
        expected = team_role_for(row.user_id)
        row.update!(team_role: expected) if row.team_role != expected
      end

      (emails - before_emails).each do |email|
        PortalNotificationRecipient.create!(company_id: company.id, email: email, added_by: actor)
      end

      all_ids = (user_ids + before_users + [ before_lead_id, before_backup_id, lead_user_id, backup_user_id ]).compact.uniq
      names = User.where(id: all_ids).pluck(:id, :name).to_h
      changes = {
        added_users: (user_ids - before_users).map { |id| { id: id, name: names[id] } },
        removed_users: (before_users - user_ids).map { |id| { id: id, name: names[id] } },
        added_emails: emails - before_emails,
        removed_emails: before_emails - emails
      }
      if before_lead_id != lead_user_id
        changes[:lead_user] = {
          before: before_lead_id ? { id: before_lead_id, name: names[before_lead_id] } : nil,
          after: lead_user_id ? { id: lead_user_id, name: names[lead_user_id] } : nil
        }
      end
      if before_backup_id != backup_user_id
        changes[:backup_user] = {
          before: before_backup_id ? { id: before_backup_id, name: names[before_backup_id] } : nil,
          after: backup_user_id ? { id: backup_user_id, name: names[backup_user_id] } : nil
        }
      end
      changes
    end
  end
end
