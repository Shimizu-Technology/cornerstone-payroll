# frozen_string_literal: true

module MigrationPromotion
  class SetupSynchronizer
    EMPLOYEE_COLUMNS_EXCLUDED = %w[
      id company_id department_id previous_employee_id test_workspace_source_employee_id created_at updated_at
    ].freeze

    def initialize(rehearsal:, target_company:, actor:, mapping:)
      @rehearsal = rehearsal
      @target_company = target_company
      @actor = actor
      @mapping = mapping
    end

    def call
      clear_replaceable_setup!
      department_map = copy_collection(rehearsal.departments, Department, company: target_company)
      employee_map = sync_employees!(department_map)
      deduction_type_map = copy_collection(rehearsal.deduction_types, DeductionType, company: target_company)
      pay_schedule_map = copy_collection(rehearsal.company_pay_schedules, CompanyPaySchedule, company: target_company)
      workweek_map = copy_collection(rehearsal.company_workweeks, CompanyWorkweek, company: target_company)
      copy_collection(rehearsal.pay_component_tax_rules, PayComponentTaxRule, company: target_company)
      field_definition_map = copy_field_definitions!(employee_map)
      copy_employee_setup!(employee_map, deduction_type_map)
      loan_map = copy_loans!(employee_map, deduction_type_map)
      copy_payroll_fields!(employee_map, field_definition_map, loan_map)

      {
        employees: employee_map,
        departments: department_map,
        deduction_types: deduction_type_map,
        pay_schedules: pay_schedule_map,
        workweeks: workweek_map,
        payroll_field_definitions: field_definition_map,
        loans: loan_map
      }
    end

    private

    attr_reader :rehearsal, :target_company, :actor, :mapping

    def clear_replaceable_setup!
      # Company-scoped payroll fields, deductions, and loans must be replaced
      # across every identity. Other employee history is replaced only for the
      # mapped workforce so archived import identities retain their evidence.
      all_employee_ids = target_company.employees.select(:id)
      mapped_employee_ids = mapping.map.values.map(&:id)
      loan_ids = target_company.employee_loans.where(employee_id: all_employee_ids).select(:id)
      LoanTransaction.where(employee_loan_id: loan_ids).delete_all
      EmployeePayrollField.where(employee_id: all_employee_ids).delete_all
      EmployeeDeduction.where(employee_id: all_employee_ids).delete_all
      EmployeeWageRate.where(employee_id: mapped_employee_ids).delete_all
      EmployeeW4Election.where(employee_id: mapped_employee_ids).delete_all
      EmployeeWorkProfile.where(employee_id: mapped_employee_ids).delete_all
      EmployeeStatusEvent.where(employee_id: mapped_employee_ids).delete_all
      EmployeeTippedOccupation.where(employee_id: mapped_employee_ids).delete_all
      EmployeeRetirementElection.where(employee_id: mapped_employee_ids).delete_all
      target_company.employee_loans.where(employee_id: all_employee_ids).delete_all

      target_company.employees.update_all(department_id: nil, updated_at: Time.current)
      target_company.employees.where(id: mapped_employee_ids).update_all(previous_employee_id: nil, updated_at: Time.current)
      target_company.payroll_field_definitions.delete_all
      target_company.deduction_types.delete_all
      target_company.pay_component_tax_rules.delete_all
      target_company.company_pay_schedules.delete_all
      target_company.company_workweeks.delete_all
      target_company.departments.delete_all
    end

    def sync_employees!(department_map)
      employee_map = mapping.map.dup
      rehearsal.employees.order(:id).each do |source|
        attributes = source.attributes.except(*EMPLOYEE_COLUMNS_EXCLUDED).merge(
          company_id: target_company.id,
          department_id: source.department_id && department_map.fetch(source.department_id).id,
          previous_employee_id: nil,
          test_workspace_source_employee_id: nil,
          portal_pending_approval: false
        )
        target = employee_map[source.id]
        if target
          target.allow_tax_classification_change = true
          target.update!(attributes)
        else
          target = Employee.create!(attributes)
          employee_map[source.id] = target
        end
      end

      rehearsal.employees.where.not(previous_employee_id: nil).find_each do |source|
        employee_map.fetch(source.id).update!(previous_employee: employee_map.fetch(source.previous_employee_id))
      end
      employee_map
    end

    def copy_employee_setup!(employee_map, deduction_type_map)
      rehearsal.employees.order(:id).each do |source|
        target = employee_map.fetch(source.id)
        copy_collection(source.employee_wage_rates, EmployeeWageRate, employee: target)
        copy_collection(source.employee_w4_elections, EmployeeW4Election, company: target_company, employee: target)
        copy_collection(source.employee_work_profiles, EmployeeWorkProfile, company: target_company, employee: target)
        copy_collection(source.employee_status_events, EmployeeStatusEvent, company: target_company, employee: target)
        copy_collection(source.employee_tipped_occupations, EmployeeTippedOccupation, employee: target)
        copy_collection(
          source.employee_retirement_elections,
          EmployeeRetirementElection,
          company: target_company,
          employee: target,
          created_by: actor
        )
        source.employee_deductions.order(:id).each do |deduction|
          copy_record!(
            deduction,
            employee: target,
            deduction_type: deduction_type_map.fetch(deduction.deduction_type_id)
          )
        end
      end
    end

    def copy_field_definitions!(employee_map)
      rehearsal.payroll_field_definitions.order(:id).each_with_object({}) do |source, result|
        result[source.id] = copy_record!(
          source,
          company: target_company,
          owner_employee: source.owner_employee_id && employee_map.fetch(source.owner_employee_id)
        )
      end
    end

    def copy_loans!(employee_map, deduction_type_map)
      rehearsal.employee_loans.order(:id).each_with_object({}) do |source, result|
        result[source.id] = copy_record!(
          source,
          company: target_company,
          employee: employee_map.fetch(source.employee_id),
          deduction_type: source.deduction_type_id && deduction_type_map.fetch(source.deduction_type_id),
          created_by: actor,
          stopped_by: source.stopped_at.present? ? actor : nil
        )
      end
    end

    def copy_payroll_fields!(employee_map, field_definition_map, loan_map)
      EmployeePayrollField.joins(:employee)
        .where(employees: { company_id: rehearsal.id })
        .order(:id)
        .each do |source|
          copy_record!(
            source,
            employee: employee_map.fetch(source.employee_id),
            payroll_field_definition: field_definition_map.fetch(source.payroll_field_definition_id),
            employee_loan: source.employee_loan_id && loan_map.fetch(source.employee_loan_id)
          )
        end
    end

    def copy_collection(scope, target_class, **overrides)
      scope.order(:id).each_with_object({}) do |source, result|
        raise ArgumentError, "Unexpected rehearsal setup record" unless source.is_a?(target_class)

        result[source.id] = copy_record!(source, **overrides)
      end
    end

    def copy_record!(source, **overrides)
      attributes = source.attributes.except("id", "created_at", "updated_at")
      source.class.create!(attributes.merge(overrides.stringify_keys))
    end
  end
end
