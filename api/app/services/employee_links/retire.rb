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
  # Reactivation and rehire don't reopen old links; a new invite is issued.
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

    def open_links(employee)
      EmployeeAccountLink.where(employee_id: employee.id, company_id: employee.company_id, status: %w[invited active])
        .order(:id).lock.to_a
    end
  end
end
