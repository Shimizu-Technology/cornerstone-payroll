# frozen_string_literal: true

module EmployeeOrganizationActions
  extend ActiveSupport::Concern

  included do
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Employee, department or role not found in this company." }, status: :not_found
    end
    rescue_from ActionController::ParameterMissing do
      render json: { error: "Provide role details." }, status: :unprocessable_entity
    end
    rescue_from ActiveRecord::RecordInvalid do |error|
      render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  def show
    render json: {
      roles: roles.order(:name).as_json(only: %i[id name active occupation_code]),
      departments: Department.where(company_id: current_company.id).order(:name).as_json(only: %i[id name active]),
      codes: CompanyJobRole::CODES
    }
  end

  def update
    input = params.permit(:department_id, :company_job_role_id, employee_ids: [])
    ids = input.fetch(:employee_ids, []).map { |id| Integer(id.to_s, 10, exception: false) }.uniq
    assignment_keys = %i[department_id company_job_role_id]
    supplied_keys = assignment_keys.select { |key| params.key?(key) }
    unless ids.present? && ids.all? { |id| id&.positive? } && ids.size <= 500 &&
        supplied_keys.present? && supplied_keys.all? { |key| valid_assignment_id?(input, key) }
      return render json: { error: "Select employees and a department or role change." }, status: :unprocessable_entity
    end

    write_organization do
      attributes = {}
      if input.key?(:department_id)
        attributes[:department_id] = Department.active.where(company_id: current_company.id).find(input[:department_id]).id if input[:department_id]
        attributes[:department_id] = nil if input[:department_id].nil?
      end
      if input.key?(:company_job_role_id)
        role = roles.where(active: true).find(input[:company_job_role_id]) if input[:company_job_role_id]
        attributes.merge!(company_job_role: role, job_title: role&.name)
      end

      employees = current_company.employees.where(id: ids).order(:id).lock.to_a
      raise ActiveRecord::RecordNotFound unless employees.size == ids.size

      employees.each { |employee| EmployeeOrganization.assign!(employee, attributes, actor: current_user) }
    end
    render json: { count: ids.size }
  end

  def save_role
    write_organization do
      role = params[:id] ? roles.find(params[:id]) : roles.new
      fields = %w[name active occupation_code]
      before = role.persisted? ? role.slice(*fields) : {}
      role_params = params.require(:role)
      raise ActionController::ParameterMissing, :role unless role_params.is_a?(ActionController::Parameters)

      role.update!(role_params.permit(*fields))
      after = role.slice(*fields)
      if before != after
        EmployeeOrganization.audit!(role, actor: current_user, before: before, after: after)
        role.employees.order(:id).lock.each do |employee|
          if role.saved_change_to_name?
            before_title = employee.slice("job_title")
            raise ActiveRecord::RecordNotSaved unless employee.update_columns(job_title: role.name)

            EmployeeOrganization.audit!(employee, actor: current_user, before: before_title, after: employee.slice("job_title"))
          end
          tip_fields = %w[active occupation_code]
          if before.slice(*tip_fields) != after.slice(*tip_fields)
            EmployeeOrganization.audit!(employee, actor: current_user,
              before: before.slice(*tip_fields).transform_keys { |key| "role_#{key}" },
              after: after.slice(*tip_fields).transform_keys { |key| "role_#{key}" })
          end
        end
      end
    end
    show
  end

  private

  def valid_assignment_id?(input, key)
    input.key?(key) && (input[key].nil? || Integer(input[key].to_s, 10, exception: false)&.positive?)
  end

  def roles
    CompanyJobRole.where(company_id: current_company.id)
  end

  def write_organization
    current_company.with_lock(requires_new: true) do
      authorize_organization_write!
      yield
    end
  end
end
