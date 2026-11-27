# frozen_string_literal: true

class WageRateDepartmentAssignment
  def initialize(company:, label_map:)
    @company = company
    @label_map = label_map
  end

  def call(apply:, overwrite: false)
    @company.with_lock do
      counts = { departments_to_create: 0, employees_to_assign: 0, already_assigned: 0, no_mapped_label: 0, inactive_department: 0, existing_department_preserved: 0 }
      departments = Department.where(company_id: @company.id).index_by(&:name)
      usages = PayrollItemEarning.joins(payroll_item: :pay_period)
        .merge(PayPeriod.reportable_committed)
        .merge(PayrollItem.reportable.financially_reportable.not_voided)
        .where(company_id: @company.id, label: @label_map.keys, category: "regular")
        .group("payroll_items.employee_id", :label).count
      @company.employees.active.includes(:employee_wage_rates).find_each do |employee|
        name = department_name(employee, usages)
        counts[:no_mapped_label] += 1 unless name
        next unless name

        department = departments[name]
        if department && !department.active?
          counts[:inactive_department] += 1
          next
        end
        if department&.persisted? && employee.department_id == department.id
          counts[:already_assigned] += 1
          next
        end
        if employee.department_id && !overwrite
          counts[:existing_department_preserved] += 1
          next
        end

        unless department
          counts[:departments_to_create] += 1
          departments[name] = Department.new(company: @company, name: name)
          if apply
            departments[name].save!
            EmployeeOrganization.audit!(departments[name], actor: nil, before: {}, after: { name: name })
          end
        end

        counts[:employees_to_assign] += 1
        assign_department!(employee, departments.fetch(name), overwrite: overwrite) if apply
      end
      counts
    end
  end

  private

  def assign_department!(employee, department, overwrite:)
    employee.lock!
    before = employee.slice("department_id")
    return if !employee.active? || employee.department_id == department.id || (employee.department_id.present? && !overwrite)

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
