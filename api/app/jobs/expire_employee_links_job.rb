# frozen_string_literal: true

# Daily sweep of the employee app links (M4-2): revokes invites nobody
# finished in 14 days, closes former-employee access when its window ends,
# and deactivates any employee-only login left with nothing eligible. That
# last step also catches logins a company-scoped close couldn't see past.
#
# Each candidate is decided again under its locks (login, then link): a
# resend may have renewed an invite, or a sign-up attached a login, since the
# candidates were read.
class ExpireEmployeeLinksJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform(now: Time.current)
    EmployeeAccountLink.where(status: "invited").where(invite_expires_at: ..now).order(:id).pluck(:id).each do |id|
      close(id, :invite, now)
    end
    EmployeeAccountLink.where(status: "former").where(former_access_until: ..now).order(:id).pluck(:id).each do |id|
      close(id, :former, now)
    end
    deactivate_logins_without_access(now)
  end

  # Returns whether the link was closed.
  def close(link_id, kind, now)
    ApplicationRecord.transaction do
      link = EmployeeAccountLink.find_by(id: link_id)
      next false unless link && EmployeeLinks::Close.lock_link_and_login!(link) && still_due?(link, kind, now)

      reason = kind == :invite ? "invite_expired" : "former_access_ended"
      EmployeeLinks::Close.revoke!(link, reason: reason, now: now)
      true
    end
  rescue StandardError => error
    # One link's failure must not stop the sweep; it is retried tomorrow.
    Rails.logger.error("[ExpireEmployeeLinksJob] link=#{link_id} #{error.class}: #{error.message}")
    false
  end

  private

  def still_due?(link, kind, now)
    if kind == :invite
      link.invited? && link.invite_expires_at.present? && link.invite_expires_at <= now
    else
      link.former? && link.former_access_until.present? && link.former_access_until <= now
    end
  end

  def deactivate_logins_without_access(now)
    eligible = EmployeeAccountLink.where(status: "active")
      .or(EmployeeAccountLink.where(status: "former").where("former_access_until > ?", now))
    User.portal_employee.active.where(invitation_status: "accepted").where.not(id: eligible.where.not(user_id: nil).select(:user_id))
      .where(id: EmployeeAccountLink.where.not(user_id: nil).select(:user_id)).order(:id).pluck(:id).each do |user_id|
      ApplicationRecord.transaction do
        user = EmployeeLinks.lock_users!([ user_id ]).first
        company_id = EmployeeAccountLink.where(user_id: user_id).order(:id).last&.company_id
        # closed_link: nil counts every link, re-read under the login's lock.
        EmployeeLinks::Close.deactivate_if_last!(user, closed_link: nil, now: now, audit_company_id: company_id) if user
      end
    rescue StandardError => error
      Rails.logger.error("[ExpireEmployeeLinksJob] user=#{user_id} #{error.class}: #{error.message}")
    end
  end
end
