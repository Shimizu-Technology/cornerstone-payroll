# frozen_string_literal: true

module EmployeeLinks
  # Called by the status-transition services, inside their transaction, when
  # a worker stops being active (§1.1).
  #
  # - Terminated: an active link becomes former, with former_access_until =
  #   termination date + the company's former_access_years (default 2).
  # - Deactivated without a termination date: the link is revoked with a
  #   reason, and no former window starts.
  # - Either way an invite nobody finished is revoked.
  #
  # Reactivation and rehire don't reopen old links, and nothing is sent
  # automatically: an admin issues a new invite.
  module Retire
    module_function

    def terminated!(employee, termination_date:, actor: nil)
      open_links(employee).each do |link|
        if link.active?
          Close.make_former!(link, termination_date: termination_date, actor: actor)
        else
          Close.revoke!(link, reason: "employment_ended", actor: actor)
        end
      end
    end

    def deactivated!(employee, actor: nil)
      open_links(employee).each do |link|
        Close.revoke!(link, reason: "worker_deactivated", actor: actor)
      end
    end

    LOCK_ATTEMPTS = 3

    # The caller holds the employee's lock. Logins are locked before their
    # links (EmployeeLinks lock order), never after: if a login was attached
    # to a link between the first read and the link locks (a sign-up that just
    # committed, whose bind may now hold that login and wait for the link),
    # the link locks are released (savepoint rollback) and the reads start
    # again from the employee lock, up to LOCK_ATTEMPTS times.
    def open_links(employee)
      scope = EmployeeAccountLink.where(employee_id: employee.id, company_id: employee.company_id, status: %w[invited active])
      LOCK_ATTEMPTS.times do
        links = EmployeeAccountLink.transaction(requires_new: true) do
          first_read = scope.order(:id).pluck(:id, :user_id).to_h
          EmployeeLinks.lock_users!(first_read.values)
          locked = scope.order(:id).lock.to_a
          raise ActiveRecord::Rollback unless locked.all? { |link| first_read.key?(link.id) && first_read[link.id] == link.user_id }

          locked
        end
        return links if links
      end
      raise Error, "This employee's app access changed while it was being closed. Try again."
    end
  end
end
