# frozen_string_literal: true

module TestWorkspace
  class SetupCloner
    def initialize(source_company:, target_company:, actor:, employee_lineage: false, loan_balance_on: nil)
      @source_company = source_company
      @target_company = target_company
      @actor = actor
      @employee_lineage = employee_lineage
      @loan_balance_on = loan_balance_on
    end

    def call
      validate!

      department_map = copy_collection(source_company.departments, Department, company: target_company)
      deduction_type_map = copy_collection(source_company.deduction_types, DeductionType, company: target_company)
      pay_schedule_map = copy_collection(
        source_company.company_pay_schedules,
        CompanyPaySchedule,
        company: target_company
      )
      workweek_map = copy_collection(
        source_company.company_workweeks,
        CompanyWorkweek,
        company: target_company
      )
      copy_collection(source_company.pay_component_tax_rules, PayComponentTaxRule, company: target_company)

      employee_map = copy_employees!(department_map)
      field_definition_map = copy_payroll_field_definitions!(employee_map)
      copy_employee_setup!(employee_map, deduction_type_map)
      loan_map = copy_loans!(employee_map, deduction_type_map)
      copy_payroll_fields!(employee_map, field_definition_map, loan_map)

      {
        employees: employee_map,
        departments: department_map,
        deduction_types: deduction_type_map,
        payroll_field_definitions: field_definition_map,
        pay_schedules: pay_schedule_map,
        workweeks: workweek_map,
        loans: loan_map
      }
    end

    private

    attr_reader :source_company, :target_company, :actor, :employee_lineage, :loan_balance_on

    def validate!
      raise ArgumentError, "Target must be a test workspace" unless target_company.test_workspace?
      raise ArgumentError, "Test workspace source changed" unless target_company.migration_source_company_id == source_company.id
      raise ArgumentError, "Source and test workspace must belong to the same organization" unless target_company.organization_id == source_company.organization_id
      raise ArgumentError, "Actor no longer belongs to this organization" unless actor.organization_id == target_company.organization_id
    end

    def copy_employees!(department_map)
      employee_map = {}
      source_company.employees.order(:id).each do |source|
        employee_map[source.id] = copy_record!(
          source,
          company: target_company,
          department: source.department_id && department_map.fetch(source.department_id),
          previous_employee_id: nil,
          portal_pending_approval: false,
          test_workspace_source_employee: employee_lineage ? source : nil
        )
      end

      source_company.employees.where.not(previous_employee_id: nil).find_each do |source|
        employee_map.fetch(source.id).update!(previous_employee: employee_map.fetch(source.previous_employee_id))
      end

      source_company.employees.order(:id).each do |source|
        employee_map.fetch(source.id).update_columns(
          configuration_source: source.configuration_source,
          configuration_review_status: source.configuration_review_status,
          configuration_review_items: source.configuration_review_items,
          updated_at: Time.current
        )
      end
      employee_map
    end

    def copy_employee_setup!(employee_map, deduction_type_map)
      source_company.employees.order(:id).each do |source|
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

    def copy_payroll_field_definitions!(employee_map)
      source_company.payroll_field_definitions.order(:id).each_with_object({}) do |source, result|
        result[source.id] = copy_record!(
          source,
          company: target_company,
          owner_employee: source.owner_employee_id && employee_map.fetch(source.owner_employee_id)
        )
      end
    end

    def copy_loans!(employee_map, deduction_type_map)
      source_company.employee_loans.order(:id).each_with_object({}) do |loan, result|
        cutoff_attributes = loan_attributes_at_cutoff(loan)
        result[loan.id] = copy_record!(
          loan,
          cutoff_attributes.merge(
            company: target_company,
            employee: employee_map.fetch(loan.employee_id),
            deduction_type: loan.deduction_type_id && deduction_type_map.fetch(loan.deduction_type_id),
            created_by: actor,
            stopped_by: cutoff_attributes.fetch(:stopped_at, loan.stopped_at).present? ? actor : nil
          )
        )
      end
    end

    def loan_attributes_at_cutoff(loan)
      return {} if loan_balance_on.blank?

      stopped_after_cutoff = loan.stopped_at.present? && loan.stopped_at.to_date > loan_balance_on
      if loan.recurring_no_balance?
        return {} unless stopped_after_cutoff

        return { status: "active", stopped_at: nil, stopped_by_id: nil }
      end

      transaction = loan.loan_transactions
        .where("transaction_date < ?", loan_balance_on)
        .order(transaction_date: :desc, id: :desc)
        .first
      balance = transaction&.balance_after || loan.opening_balance
      status = balance.to_d.zero? ? "paid_off" : loan.status
      status = "active" if status == "paid_off" && balance.to_d.positive?
      status = "active" if stopped_after_cutoff

      {
        current_balance: balance,
        balance_as_of: transaction&.transaction_date || loan.balance_as_of,
        status: status,
        paid_off_date: status == "paid_off" ? [ loan.paid_off_date, loan_balance_on ].compact.min : nil,
        stopped_at: stopped_after_cutoff ? nil : loan.stopped_at,
        stopped_by_id: stopped_after_cutoff ? nil : loan.stopped_by_id
      }
    end

    def copy_payroll_fields!(employee_map, field_definition_map, loan_map)
      EmployeePayrollField.joins(:employee)
        .where(employees: { company_id: source_company.id })
        .order(:id)
        .each do |field|
          copy_record!(
            field,
            employee: employee_map.fetch(field.employee_id),
            payroll_field_definition: field_definition_map.fetch(field.payroll_field_definition_id),
            employee_loan: field.employee_loan_id && loan_map.fetch(field.employee_loan_id)
          )
        end
    end

    def copy_collection(scope, target_class, **overrides)
      scope.order(:id).each_with_object({}) do |source, result|
        raise ArgumentError, "Unexpected test workspace source type" unless source.is_a?(target_class)

        result[source.id] = copy_record!(source, overrides)
      end
    end

    def copy_record!(source, overrides = {})
      attributes = source.attributes.except("id", "created_at", "updated_at")
      source.class.create!(attributes.merge(overrides.stringify_keys))
    end
  end
end
