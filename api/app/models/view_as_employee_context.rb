# frozen_string_literal: true

# The read interface shared with EmployeeAccountLink. A worker without a
# login needs no synthetic database row, even when support views a former job.
class ViewAsEmployeeContext
  attr_reader :employee, :company, :link, :status, :former_access_until

  delegate :id, :user, to: :link, allow_nil: true
  delegate :id, to: :company, prefix: true
  delegate :id, to: :employee, prefix: true

  def self.resolve(employee, company)
    links = EmployeeAccountLink.where(company: company, employee: employee)
    link = links.where(status: %w[active former]).order(created_at: :desc, id: :desc).first
    if link
      user = link.user
      return unless user&.active? && !user.staff_member? && user.organization_id == company.organization_id
    end
    if link.nil? && links.where(status: "revoked").joins(:user).where(users: { invitation_status: "accepted" }).exists?
      return
    end

    context = new(employee, company, link)
    return if context.former? && context.former_access_until && context.former_access_until <= Time.current

    context
  end

  def initialize(employee, company, link)
    @employee = employee
    @company = company
    @link = link
    @status = employee.active? && !link&.former? ? "active" : "former"
    @former_access_until = link&.former_access_until
    if former? && @former_access_until.nil? && employee.termination_date
      years = EmployeeLinks::Close.former_access_years(company)
      @former_access_until = (employee.termination_date + years.years).in_time_zone(PayrollBusinessClock::TIME_ZONE).end_of_day
    end
  end

  def former?
    status == "former"
  end

  def active?
    status == "active"
  end
end
