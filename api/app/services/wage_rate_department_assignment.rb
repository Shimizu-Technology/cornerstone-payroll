# frozen_string_literal: true

class WageRateDepartmentAssignment
  def initialize(company:, label_map:)
    @company = company
    @label_map = label_map
  end

  def call(apply:)
    @company.with_lock do
      counts = { departments_to_create: 0, employees_to_assign: 0, already_assigned: 0, no_mapped_label: 0 }
      departments = Department.where(company_id: @company.id).index_by(&:name)
      usages = PayrollItemEarning.joins(:payroll_item)
        .where(company_id: @company.id, label: @label_map.keys, category: "regular")
        .group("payroll_items.employee_id", :label).count
      @company.employees.active.includes(:employee_wage_rates).find_each do |employee|
        name = department_name(employee, usages)
        counts[:no_mapped_label] += 1 unless name
        next unless name

        unless departments.key?(name)
          counts[:departments_to_create] += 1
          departments[name] = Department.new(company: @company, name: name)
          if apply
            departments[name].save!
            EmployeeOrganization.audit!(departments[name], actor: nil, before: {}, after: { name: name })
          end
        end

        department = departments.fetch(name)
        if department.persisted? && employee.department_id == department.id
          counts[:already_assigned] += 1
        else
          counts[:employees_to_assign] += 1
          assign_department!(employee, department) if apply
        end
      end
      counts
    end
  end

  private

  def assign_department!(employee, department)
    employee.lock!
    before = employee.slice("department_id")
    return if employee.department_id == department.id

    # This rollout changes only the department, even for legacy employee rows.
    raise ActiveRecord::RecordNotSaved unless employee.update_columns(department_id: department.id)

    EmployeeOrganization.audit!(employee, actor: nil, before: before, after: employee.slice("department_id"))
  end

  def department_name(employee, usages)
    rates = employee.employee_wage_rates.select(&:active?)
    primary = rates.find(&:is_primary?)
    return @label_map[primary.label] if primary && @label_map.key?(primary.label)

    candidates = rates.filter_map do |rate|
      count = usages.fetch([ employee.id, rate.label ], 0)
      [ count, @label_map.fetch(rate.label) ] if count.positive? && @label_map.key?(rate.label)
    end
    max_usage = candidates.map(&:first).max
    winners = candidates.select { |count, _name| count == max_usage }.map(&:last).uniq
    winners.first if winners.one?
  end
end
