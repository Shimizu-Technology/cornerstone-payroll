# frozen_string_literal: true

module PayrollSubmissions
  # Projects immutable client evidence into a review. No payroll writes happen
  # until staff confirms the complete list in the successful apply transaction.
  class ImportChanges
    def initialize(submission:, pay_period:)
      @submission = submission
      @period = pay_period
    end

    def proposals
      @submission.change_rows.each_with_index.filter_map do |row, index|
        next unless %w[owner_pay extra_hours].include?(row["kind"]) && !row["skipped"]
        next if legacy_manual_row?(row)

        employee = Employee.find_by(company_id: @period.company_id, id: row["employee_id"])
        error = availability_error(row, employee)
        existing = @period.payroll_items.find_by(employee_id: employee.id) if employee
        rate = employee&.active_wage_rates&.find_by(id: row["employee_wage_rate_id"]) if row["kind"] == "extra_hours"
        { change_index: index, kind: row["kind"], employee_id: row["employee_id"], employee_name: employee&.full_name,
          amount: row["amount"], hours: row["hours"], employee_wage_rate_id: row["employee_wage_rate_id"],
          wage_rate_label: rate&.label, wage_rate: rate&.rate&.to_s("F"), error: error,
          overwrite_required: existing.present? && existing.import_source != "mosa_revel",
          saved_regular_hours: existing&.hours_worked&.to_s("F"), saved_overtime_hours: existing&.overtime_hours&.to_s("F") }.compact
      end
    end

    def apply_to(rows, reviewed:, confirmed:, source_employee_ids: rows.map { |row| row[:employee_id] })
      changes = proposals
      return rows if changes.empty?
      raise ArgumentError, "Confirm the amounts and hours from the client's changes before applying." unless ActiveModel::Type::Boolean.new.cast(confirmed)
      raise ArgumentError, changes.filter_map { |row| row[:error] }.join(" ") if changes.any? { |row| row[:error] }

      reviewed = Array(reviewed).map { |row| row.to_h.with_indifferent_access }
      unless reviewed.map { |row| row[:change_index].to_s }.sort == changes.map { |row| row[:change_index].to_s }.sort
        raise ArgumentError, "Review every owner-pay and extra-hours change before applying."
      end
      changes.each do |change|
        if rows.none? { |row| row[:employee_id].to_s == change[:employee_id].to_s } && !source_employee_ids.map(&:to_s).include?(change[:employee_id].to_s)
          employee = Employee.find_by!(id: change[:employee_id], company_id: @period.company_id)
          rows << PayrollImport::ImportService.new(@period).client_change_preview(employee)
        end
        matches = rows.select { |row| row[:employee_id].to_s == change[:employee_id].to_s }
        raise ArgumentError, "#{change[:employee_name]} must have exactly one included import row. Resolve the client change before applying." unless matches.one?

        row = matches.sole
        input = reviewed.find { |value| value[:change_index].to_s == change[:change_index].to_s }
        field = change[:kind] == "owner_pay" ? :amount : :hours
        value = input[field].to_s
        unless value.match?(/\A\d{1,9}(\.\d{1,2})?\z/) && value.to_d.positive? && value.to_d <= (field == :hours ? 1000 : 10_000_000)
          raise ArgumentError, "Enter a valid #{field} greater than zero for #{change[:employee_name]}."
        end
        if field == :amount
          row[:period_pay] = value
          row[:period_pay_evidence] = { scope: "THIS EMPLOYEE ONLY", source: "Client revision #{@submission.revision}",
            effective_pay_date: @period.pay_date.iso8601, source_type: "client_submission", submission_id: @submission.id,
            change_index: change[:change_index], submitted_amount: change[:amount] }
        else
          # Extra hours are additive to Revel; workbook-only rows start from the
          # worksheet hours already saved. Never replace workbook tips or loans.
          row[:client_extra_hours] = { hours: value, employee_wage_rate_id: change[:employee_wage_rate_id], rate: change[:wage_rate] }
          row[:missing_revel_hours_with_deductions] = false
        end
        row[:client_change_evidence] = change.merge(submission_id: @submission.id, reviewed_value: value)
      end
      rows
    end

    def manual_review_warnings
      @submission.change_rows.filter_map do |row|
        next unless legacy_manual_row?(row) && !row["skipped"]

        row["kind"] == "owner_pay" ?
          "Legacy owner pay uses a total/each amount. Enter each owner's own period pay manually; no split is inferred." :
          "Legacy extra hours have no saved job. Enter and check these hours on the worksheet; no job or rate is inferred."
      end.uniq
    end

    private

    def legacy_manual_row?(row)
      return false if row["standing_change_id"]

      (row["kind"] == "owner_pay" && !row["employee_id"]) ||
        (row["kind"] == "extra_hours" && !row["employee_wage_rate_id"])
    end

    def availability_error(row, employee)
      return "Legacy owner pay lists a total/each amount. Enter each owner's pay separately; names and splits cannot be inferred." if row["kind"] == "owner_pay" && !row["employee_id"]
      return "The employee for this client change is missing or belongs to another company." unless employee
      return "#{employee.full_name} is #{employee.status}. Resolve this client change before applying." unless employee.active?
      unless Employee.where(id: employee.id).eligible_for_period(@period.start_date, @period.end_date).exists?
        return "#{employee.full_name} is not eligible for this pay period. Resolve this client change before applying."
      end
      if @period.pay_period_excluded_employees.exists?(employee_id: employee.id)
        return "#{employee.full_name} is excluded from this pay period. Resolve this client change before applying."
      end
      return "#{employee.full_name} no longer uses variable salary." if row["kind"] == "owner_pay" && !employee.variable_salary?
      if row["kind"] == "extra_hours"
        rate = employee.active_wage_rates.find_by(id: row["employee_wage_rate_id"])
        unless employee.hourly_pay_basis? && rate && rate.rate && rate.rate == row["wage_rate"].to_d
          return "Saved job and rate are missing, inactive or changed for #{employee.full_name}. Resolve this client change before applying."
        end
      end
      nil
    end
  end
end
