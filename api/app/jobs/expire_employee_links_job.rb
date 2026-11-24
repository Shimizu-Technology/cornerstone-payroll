# frozen_string_literal: true

# Daily sweep of the employee app links (M4-2): revokes invites nobody
# finished in 14 days, closes former-employee access when its window ends,
# and deactivates any employee-only login left with nothing eligible. That
# last step also catches logins a company-scoped close couldn't see past.
class ExpireEmployeeLinksJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform(now: Time.current)
    EmployeeAccountLink.where(status: "invited").where(invite_expires_at: ..now).order(:id).find_each do |link|
      close(link) { EmployeeLinks::Close.revoke!(link, reason: "invite_expired", now: now) }
    end
    EmployeeAccountLink.where(status: "former").where(former_access_until: ..now).order(:id).find_each do |link|
      close(link) { EmployeeLinks::Close.revoke!(link, reason: "former_access_ended", now: now) }
    end
    deactivate_logins_without_access(now)
  end

  private

  def close(link)
    ApplicationRecord.transaction do
      link.lock!
      yield if link.invited? || link.former?
    end
  rescue StandardError => error
    # One link's failure must not stop the sweep; it is retried tomorrow.
    Rails.logger.error("[ExpireEmployeeLinksJob] link=#{link.id} #{error.class}: #{error.message}")
  end

  def deactivate_logins_without_access(now)
    eligible = EmployeeAccountLink.where(status: "active")
      .or(EmployeeAccountLink.where(status: "former").where("former_access_until > ?", now))
    User.portal_employee.active.where(invitation_status: "accepted").where.not(id: eligible.where.not(user_id: nil).select(:user_id))
      .where(id: EmployeeAccountLink.where.not(user_id: nil).select(:user_id)).order(:id).find_each do |user|
      ApplicationRecord.transaction do
        link = EmployeeAccountLink.where(user_id: user.id).order(:id).last
        EmployeeLinks::Close.deactivate_if_last!(user, closed_link: link, now: now)
      end
    rescue StandardError => error
      Rails.logger.error("[ExpireEmployeeLinksJob] user=#{user.id} #{error.class}: #{error.message}")
    end
  end
end
