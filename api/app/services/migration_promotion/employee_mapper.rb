# frozen_string_literal: true

require "set"

module MigrationPromotion
  class EmployeeMapper
    Result = Data.define(:map, :new_employees, :blockers) do
      def summary
        {
          matched: map.length,
          new: new_employees.length,
          blockers: blockers
        }
      end

      def ready?
        blockers.empty?
      end
    end

    def initialize(rehearsal:)
      @rehearsal = rehearsal
      @target_company = rehearsal.migration_source_company
    end

    def call
      employee_map = {}
      new_employees = []
      blockers = []
      claimed_target_ids = Set.new
      source_workers = source_workers_by_employee
      target_workers = target_workers_by_external_key
      historical_target_employee_ids = target_workers.values.filter_map(&:employee_id).to_set
      target_by_ssn = target_employees_by_ssn

      rehearsal.employees.order(:id).each do |source|
        candidates = candidate_target_ids(source, source_workers, target_workers, target_by_ssn)
        if candidates.length > 1
          blockers << "#{source.full_name} matches multiple employees in the clean client"
          next
        end

        target_id = candidates.first
        if target_id
          if claimed_target_ids.include?(target_id)
            blockers << "Multiple rehearsal employees map to the same clean-client employee"
            next
          end
          employee_map[source.id] = target_company.employees.find(target_id)
          claimed_target_ids << target_id
        elsif source_workers.fetch(source.id, []).any?
          blockers << "#{source.full_name} is linked to imported payroll but has no clean-client employee match"
        else
          new_employees << source
        end
      end

      unmatched = target_company.employees.where.not(id: claimed_target_ids.to_a).order(:last_name, :first_name).to_a
      unmatched.reject! { |employee| historical_only_target_employee?(employee, historical_target_employee_ids) }
      if unmatched.any?
        verb = unmatched.one? ? "is" : "are"
        blockers << "#{unmatched.length} clean-client #{'employee'.pluralize(unmatched.length)} #{verb} missing from the rehearsal"
      end

      Result.new(map: employee_map, new_employees: new_employees, blockers: blockers.uniq)
    end

    private

    attr_reader :rehearsal, :target_company

    def candidate_target_ids(source, source_workers, target_workers, target_by_ssn)
      if source.test_workspace_source_employee_id.present? &&
          source.test_workspace_source_employee&.company_id == target_company.id
        return [ source.test_workspace_source_employee_id ]
      end

      ssn_candidates = target_by_ssn.fetch(source.ssn_digits, []) if source.ssn_digits.present?
      if ssn_candidates.present?
        same_status = ssn_candidates.select { |candidate| candidate.status == source.status }
        return same_status.map(&:id) if same_status.any?

        return ssn_candidates.map(&:id)
      end

      ids = []
      source_workers.fetch(source.id, []).each do |worker|
        target = target_workers[worker.external_key]
        ids << target.employee_id if target&.employee_id
      end
      ids.compact.uniq
    end

    def historical_only_target_employee?(employee, historical_target_employee_ids)
      employee.status == "inactive" && historical_target_employee_ids.include?(employee.id)
    end

    def source_workers_by_employee
      batch = rehearsal.historical_import_batches.find_by(bundle_digest: rehearsal.migration_source_batch&.bundle_digest)
      return Hash.new { |hash, key| hash[key] = [] } unless batch

      batch.historical_workers.where.not(employee_id: nil).order(:id).group_by(&:employee_id)
    end

    def target_workers_by_external_key
      batch = rehearsal.migration_source_batch
      return {} unless batch

      batch.historical_workers.order(:id).index_by(&:external_key)
    end

    def target_employees_by_ssn
      target_company.employees.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |employee, result|
        result[employee.ssn_digits] << employee if employee.ssn_digits.present?
      end
    end
  end
end
