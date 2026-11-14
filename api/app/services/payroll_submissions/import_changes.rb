# frozen_string_literal: true

module PayrollSubmissions
  # Projects immutable client evidence into a review. Decisions are retained only
  # inside the successful import transaction, together with the payroll writes.
  class ImportChanges
    attr_reader :review_decisions

    def initialize(submission:, pay_period:)
      @submission = submission
      @period = pay_period
      @review_decisions = []
    end

    def proposals(source_rows: [])
      @submission.change_rows.each_with_index.filter_map do |row, index|
        next unless %w[owner_pay extra_hours].include?(row["kind"]) && !row["skipped"]
        next if legacy_manual_row?(row)

        employee = Employee.find_by(company_id: @period.company_id, id: row["employee_id"])
        existing = @period.payroll_items.find_by(employee_id: employee.id) if employee
        rate = active_rate(employee, row["employee_wage_rate_id"]) if row["kind"] == "extra_hours"
        previous = existing&.custom_columns_data.to_h.fetch("client_change_evidence", {}).to_h
        source = source_rows.find { |item| item[:employee_id].to_s == row["employee_id"].to_s }
        pay = pay_state(existing, source)
        { change_index: index, kind: row["kind"], employee_id: row["employee_id"], employee_name: employee&.full_name,
          amount: row["amount"], hours: row["hours"], employee_wage_rate_id: row["employee_wage_rate_id"],
          wage_rate_label: rate&.label, wage_rate: rate&.rate&.to_s("F"), error: availability_error(row, employee),
          overwrite_required: existing.present? && existing.import_source != "mosa_revel",
          saved_regular_hours: previous["kind"] == "extra_hours" ? previous["baseline_regular_hours"] : existing&.hours_worked&.to_s("F"),
          saved_overtime_hours: existing&.overtime_hours&.to_s("F"),
          **(row["kind"] == "owner_pay" ? pay.merge(pay_conflict: pay.values.compact.any? { |amount| amount.to_d != row["amount"].to_d }) : {}) }.compact
      end
    end

    def removals
      prior_items.filter_map do |item|
        evidence = item.custom_columns_data.to_h["client_change_evidence"].to_h
        next unless evidence["kind"] == "extra_hours"

        old = PayrollSubmission.find_by(id: evidence["submission_id"])
        "#{item.employee.full_name}: revision #{old&.revision || '?'}'s #{evidence['reviewed_value']} h will be removed before this revision is applied."
      end
    end

    def apply_to(rows, reviewed:, confirmed:, source_employee_ids: rows.map { |row| row[:employee_id] })
      changes = proposals(source_rows: rows)
      @review_decisions = []
      reviewed = Array(reviewed).map { |row| row.to_h.with_indifferent_access }
      if changes.any? && !ActiveModel::Type::Boolean.new.cast(confirmed)
        raise ArgumentError, "Confirm the amounts and hours from the client's changes before applying."
      end
      unless reviewed.map { |row| row[:change_index].to_s }.sort == changes.map { |row| row[:change_index].to_s }.sort
        raise ArgumentError, "Review every owner-pay and extra-hours change before applying."
      end
      changes.each do |change|
        input = reviewed.find { |value| value[:change_index].to_s == change[:change_index].to_s }
        decision = input[:decision].presence || "apply"
        raise ArgumentError, "Choose Apply or Don't apply for #{change[:employee_name]}." unless %w[apply decline].include?(decision)
        reason = input[:reason].to_s.strip
        if decision == "decline"
          raise ArgumentError, "Enter a reason (up to 1000 characters) for declining #{change[:employee_name]}." unless reason.present? && reason.length <= 1000

          @review_decisions << change.merge(decision: decision, reason: reason)
          next
        end
        raise ArgumentError, change[:error] if change[:error]

        if rows.none? { |row| row[:employee_id].to_s == change[:employee_id].to_s } && !source_employee_ids.map(&:to_s).include?(change[:employee_id].to_s)
          employee = Employee.find_by!(id: change[:employee_id], company_id: @period.company_id)
          rows << PayrollImport::ImportService.new(@period).client_change_preview(employee)
        end
        matches = rows.select { |row| row[:employee_id].to_s == change[:employee_id].to_s }
        raise ArgumentError, "#{change[:employee_name]} must have exactly one included import row. Resolve the client change before applying." unless matches.one?

        row = matches.sole
        field = change[:kind] == "owner_pay" ? :amount : :hours
        value = input[field].to_s
        unless value.match?(/\A\d{1,9}(\.\d{1,2})?\z/) && value.to_d.positive? && value.to_d <= (field == :hours ? 1000 : 10_000_000)
          raise ArgumentError, "Enter a valid #{field} greater than zero for #{change[:employee_name]}."
        end
        if field == :amount
          apply_owner_pay!(row, change, input, value)
        else
          row[:client_extra_hours] = { hours: value, employee_wage_rate_id: change[:employee_wage_rate_id], rate: change[:wage_rate] }
          row[:missing_revel_hours_with_deductions] = false
          # An employee absent from both files has no review job picker; the client
          # already named the saved job for these hours.
          row[:selected_wage_rate_id] ||= change[:employee_wage_rate_id] if row[:payroll_setup_only]
        end
        row[:client_change_evidence] = change.merge(submission_id: @submission.id, reviewed_value: value) if field == :hours || row.dig(:period_pay_evidence, :source_type) == "client_submission"
        applied_value = field == :hours ? value : (row[:period_pay].presence || change[:saved_period_pay] || value)
        @review_decisions << change.merge(decision: decision, reviewed_value: value, applied_value: applied_value, pay_choice: input[:pay_choice])
      end
      # Also process employees absent from BOTH source files and this revision.
      # These cleanup rows restore only client hours; workbook money is retained.
      prior_items.each do |item|
        next if rows.any? { |row| row[:employee_id].to_s == item.employee_id.to_s }
        if item.custom_columns_data.to_h.dig("client_change_evidence", "kind") == "owner_pay"
          raise ArgumentError, "#{item.employee.full_name}: earlier client owner pay is no longer selected. Enter current pay on the worksheet or explicitly resolve this employee before importing."
        end
        next unless item.custom_columns_data.to_h.dig("client_change_evidence", "kind") == "extra_hours"

        rows << { employee_id: item.employee_id, restore_client_hours_only: true }
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

    def prior_items
      @period.payroll_items.includes(:employee).select do |item|
        evidence = item.custom_columns_data.to_h["client_change_evidence"].to_h
        evidence["submission_id"].present? && evidence["submission_id"].to_s != @submission.id.to_s
      end
    end

    def pay_state(item, source)
      { saved_period_pay: (item.salary_override.to_d.to_s("F") if item&.salary_override.to_d.positive?),
        workbook_period_pay: (source[:period_pay].to_s if source && source[:period_pay].to_d.positive?) }
    end

    def apply_owner_pay!(row, change, input, value)
      pay = change.slice(:saved_period_pay, :workbook_period_pay)
      conflict = pay.values.compact.any? { |amount| amount.to_d != value.to_d }
      choice = input[:pay_choice].presence
      if conflict || choice
        unless %w[client saved workbook].include?(choice) && pay.all? { |key, amount| amount.to_d == input[key].to_d }
          raise ArgumentError, "Choose which pay to use for #{change[:employee_name]}; saved or workbook pay differs. Review the current amounts again."
        end
        if choice == "saved"
          item = @period.payroll_items.find_by!(employee_id: change[:employee_id])
          raise ArgumentError, "Saved pay is missing for #{change[:employee_name]}." unless pay[:saved_period_pay].to_d.positive?

          row[:period_pay] = pay[:saved_period_pay]
          row[:period_pay_evidence] = item.custom_columns_data.to_h["period_pay_evidence"].to_h.deep_symbolize_keys
          if row[:period_pay_evidence].empty?
            row.delete(:period_pay)
            row.delete(:period_pay_evidence)
          end
          return
        elsif choice == "workbook"
          raise ArgumentError, "Workbook pay is missing for #{change[:employee_name]}." unless pay[:workbook_period_pay].to_d.positive?

          return
        end
      end
      row[:period_pay] = value
      row[:period_pay_evidence] = { scope: "THIS EMPLOYEE ONLY", source: "Client revision #{@submission.revision}",
        effective_pay_date: @period.pay_date.iso8601, source_type: "client_submission", submission_id: @submission.id,
        change_index: change[:change_index], submitted_amount: change[:amount] }
    end

    def active_rate(employee, id)
      employee&.active_wage_rates&.find { |rate| rate.id.to_s == id.to_s }
    end

    def legacy_manual_row?(row)
      return false if row["standing_change_id"]

      (row["kind"] == "owner_pay" && !row["employee_id"]) ||
        (row["kind"] == "extra_hours" && !row["employee_wage_rate_id"])
    end

    def availability_error(row, employee)
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
        rate = active_rate(employee, row["employee_wage_rate_id"])
        unless employee.hourly_pay_basis? && rate && rate.rate && rate.rate == row["wage_rate"].to_d
          return "Saved job and rate are missing, inactive or changed for #{employee.full_name}. Resolve this client change before applying."
        end
      end
      nil
    end
  end
end
