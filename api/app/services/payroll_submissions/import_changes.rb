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
      submitted = @submission.change_rows.each_with_index.filter_map do |row, index|
        next unless %w[owner_pay extra_hours].include?(row["kind"]) && !row["skipped"]
        next if legacy_manual_row?(row)

        employee = Employee.find_by(company_id: @period.company_id, id: row["employee_id"])
        existing = @period.payroll_items.find_by(employee_id: employee.id) if employee
        rate = active_rate(employee, row["employee_wage_rate_id"]) if row["kind"] == "extra_hours"
        previous = existing&.custom_columns_data.to_h.fetch("client_change_evidence", {}).to_h
        source = source_rows.find { |item| item[:employee_id].to_s == row["employee_id"].to_s }
        pay = pay_state(existing, source)
        { change_index: index, kind: row["kind"], employee_id: row["employee_id"], employee_name: employee&.full_name,
          standing_change_id: row["standing_change_id"], revision: @submission.revision,
          previous_value: previous["reviewed_value"], amount: row["amount"], hours: row["hours"], employee_wage_rate_id: row["employee_wage_rate_id"],
          wage_rate_label: rate&.label, wage_rate: rate&.rate&.to_s("F"), error: availability_error(row, employee),
          overwrite_required: existing.present? && existing.import_source != "mosa_revel",
          saved_regular_hours: previous["kind"] == "extra_hours" ? previous["baseline_regular_hours"] : existing&.hours_worked&.to_s("F"),
          saved_overtime_hours: existing&.overtime_hours&.to_s("F"),
          **(row["kind"] == "owner_pay" ? pay.merge(pay_conflict: pay.values.compact.any? { |amount| amount.to_d != row["amount"].to_d }) : {}) }.compact
      end
      submitted + missing_owner_pay(submitted, source_rows)
    end

    def removals
      prior_items.filter_map do |item|
        evidence = item.custom_columns_data.to_h["client_change_evidence"].to_h
        next unless evidence["kind"] == "extra_hours"

        old = PayrollSubmission.find_by(id: evidence["submission_id"])
        "#{item.employee.full_name}: revision #{old&.revision || '?'}'s #{evidence['reviewed_value']} h will be removed before this revision is applied."
      end
    end

    def apply_to(rows, reviewed:, confirmed:, source_employee_ids: rows.map { |row| row[:employee_id] }, dispositions: [])
      changes = proposals(source_rows: rows)
      @review_decisions = []
      reviewed = Array(reviewed).map { |row| row.to_h.with_indifferent_access }
      changes.select { |change| change[:requires_pay_decision] }.each do |change|
        next if reviewed.any? { |input| input[:change_index].to_s == change[:change_index].to_s }

        exclusions = dispositions.select { |decision| decision.row.employee_id == change[:employee_id] }
        if exclusions.any? && exclusions.all? { |decision| decision.disposition == "excluded" }
          reviewed << { change_index: change[:change_index], decision: "no_pay", reason: exclusions.map(&:reason).uniq.join("; ") }.with_indifferent_access
        else
          left_out = source_employee_ids.map(&:to_s).include?(change[:employee_id].to_s) && rows.none? { |row| row[:employee_id].to_s == change[:employee_id].to_s }
          hint = left_out ? " To use the workbook's pay, include #{change[:employee_name]}'s file row instead of deferring it." : ""
          raise ArgumentError, "#{change[:employee_name]}: earlier client owner pay is no longer selected. Enter new pay in this review, or choose No pay this period / Exclude from payroll and record a reason.#{hint}"
        end
      end
      if changes.any? && !ActiveModel::Type::Boolean.new.cast(confirmed)
        raise ArgumentError, "Confirm the amounts and hours from the client's changes before applying."
      end
      unless reviewed.map { |row| row[:change_index].to_s }.sort == changes.map { |row| row[:change_index].to_s }.sort
        raise ArgumentError, "Review every owner-pay and extra-hours change before applying."
      end
      changes.each do |change|
        input = reviewed.find { |value| value[:change_index].to_s == change[:change_index].to_s }
        decision = input[:decision].presence || "apply"
        allowed = change[:requires_pay_decision] ? %w[apply no_pay] : %w[apply decline]
        raise ArgumentError, "Choose a valid pay decision for #{change[:employee_name]}." unless allowed.include?(decision)
        reason = input[:reason].to_s.strip
        if %w[decline no_pay].include?(decision)
          raise ArgumentError, "Enter a reason (up to 1000 characters) for #{decision == "no_pay" ? "no pay this period for" : "declining"} #{change[:employee_name]}." unless reason.present? && reason.length <= 1000

          if decision == "no_pay"
            rows.reject! { |row| row[:employee_id].to_s == change[:employee_id].to_s }
          end
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
        if !change[:requires_pay_decision] && value.to_d != change[field].to_d
          reason = input[:reason].to_s.strip
          raise ArgumentError, "Enter a reason (up to 1000 characters) for changing #{change[:employee_name]}'s client entry." unless reason.present? && reason.length <= 1000
        end
        if field == :amount
          apply_owner_pay!(row, change, input, value)
        else
          row[:client_extra_hours] = { hours: value, employee_wage_rate_id: change[:employee_wage_rate_id], rate: change[:wage_rate] }
          row[:missing_revel_hours_with_deductions] = false
          # An employee absent from both files has no review job picker; the client
          # already named the saved job for these hours. Hours of their own still
          # need a staff choice, so only preselect when they have none.
          row[:selected_wage_rate_id] ||= change[:employee_wage_rate_id] if row[:payroll_setup_only] && own_hours(change[:employee_id]).zero?
        end
        row[:client_change_evidence] = change.merge(submission_id: @submission.id, reviewed_value: value) if field == :hours || row.dig(:period_pay_evidence, :source_type) == "client_submission"
        applied_value = field == :hours ? value : (row[:period_pay].presence || change[:saved_period_pay] || value)
        @review_decisions << change.merge(decision: decision, reviewed_value: value, applied_value: applied_value, pay_choice: input[:pay_choice], reason: input[:reason])
      end
      # Also process employees absent from BOTH source files and this revision.
      # These cleanup rows restore only client hours; workbook money is retained.
      prior_items.each do |item|
        next if rows.any? { |row| row[:employee_id].to_s == item.employee_id.to_s }
        next if @review_decisions.any? { |decision| decision[:employee_id] == item.employee_id && decision[:decision] == "no_pay" }
        next unless item.custom_columns_data.to_h.dig("client_change_evidence", "kind") == "extra_hours"

        rows << { employee_id: item.employee_id, restore_client_hours_only: true }
      end
      rows
    end

    # Called only inside the successful import transaction. Match the worksheet's
    # exclusion semantics: remove the paycheck item, keep a reasoned roster exclusion.
    def apply_period_decisions!(actor:)
      apply_entry_resolutions!
      @review_decisions.each do |decision|
        if decision[:decision] == "no_pay"
          # Keep an exclusion staff already recorded; only one this decision
          # creates may later be undone by a client revision.
          unless @period.pay_period_excluded_employees.exists?(employee_id: decision[:employee_id])
            exclusion = @period.pay_period_excluded_employees.create!(employee_id: decision[:employee_id], reason: decision[:reason], excluded_by: actor)
            decision[:exclusion_id] = exclusion.id
          end
          begin
            @period.payroll_items.where(employee_id: decision[:employee_id]).find_each(&:destroy!)
          rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::DeleteRestrictionError
            raise ArgumentError, "#{decision[:employee_name]} already has a check, payment or tax record on this pay run. Resolve it before choosing No pay this period."
          end
          @period.invalidate_calculation!(reason: "Owner excluded after a reviewed no-pay decision.")
        elsif decision[:decision] == "apply" && decision[:kind] == "owner_pay"
          managed_owner_exclusion(decision[:employee_id])&.destroy!
        end
      end
    end

    def restorable_owner_ids
      @submission.change_rows.filter_map do |row|
        row["employee_id"].to_i if row["kind"] == "owner_pay" && !row["skipped"] && managed_owner_exclusion(row["employee_id"])
      end
    end

    # Owners this review leaves without a paycheck, with the reason: a new no-pay
    # decision, or an earlier no-pay exclusion kept because restored pay was declined.
    def unpaid_owners
      restored = @review_decisions.filter_map { |decision| decision[:employee_id].to_i if decision[:decision] == "apply" && decision[:kind] == "owner_pay" }
      kept = (restorable_owner_ids - restored).index_with { |id| managed_owner_exclusion(id).reason }
      kept.merge(@review_decisions.select { |decision| decision[:decision] == "no_pay" }.to_h { |decision| [ decision[:employee_id].to_i, decision[:reason] ] })
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

    # Revision-owned resolutions are replaced transactionally with the payroll writes.
    # Staff resolutions are never removed by a client revision.
    def apply_entry_resolutions!
      PayrollEntryResolution.where(pay_period: @period).find_each do |resolution|
        next unless resolution.source_evidence["submission_id"].present?

        source = PayrollSubmission.find_by(id: resolution.source_evidence["submission_id"])
        resolution.destroy! if source&.payroll_submission_period_id == @submission.payroll_submission_period_id
      end
      @submission.change_rows.each do |row|
        next unless row["standing_change_id"] && row["skipped"]

        field = PayrollStandingChange.find_by(id: row["standing_change_id"], company_id: @period.company_id)
        raise ArgumentError, "Configured entry changed. Review this revision before applying." unless field && field.active? && field.allow_none? && field.employee_id == row["employee_id"] && field.kind == row["kind"] && field.employee_wage_rate_id == row["employee_wage_rate_id"] && field.availability_error.nil?

        resolution = PayrollEntryResolution.find_or_initialize_by(pay_period: @period, payroll_standing_change: field)
        next if resolution.persisted? # Preserve an explicit staff answer.

        resolution.update!(employee_id: field.employee_id, note: row["note"],
          source_evidence: { submission_id: @submission.id, revision: @submission.revision })
      end
    end

    def missing_owner_pay(submitted, source_rows)
      prior_items.filter_map do |item|
        next unless item.custom_columns_data.to_h.dig("client_change_evidence", "kind") == "owner_pay"
        # A deliberate worksheet/review save clears period-pay provenance and
        # already supplies a fresh staff amount, even if the client tag remains.
        next unless item.custom_columns_data.to_h.dig("period_pay_evidence", "source_type") == "client_submission"
        next if submitted.any? { |change| change[:kind] == "owner_pay" && change[:employee_id].to_s == item.employee_id.to_s }
        # A corrected workbook with this owner's pay supplies the new amount.
        next if pay_state(nil, source_rows.find { |row| row[:employee_id].to_s == item.employee_id.to_s })[:workbook_period_pay]

        { change_index: -item.employee_id, kind: "owner_pay", employee_id: item.employee_id,
          employee_name: item.employee.full_name, requires_pay_decision: true,
          overwrite_required: item.import_source != "mosa_revel",
          error: availability_error({ "kind" => "owner_pay" }, item.employee) }.compact
      end
    end

    # An unrelated worksheet exclusion must never be undone by a client revision.
    def managed_owner_exclusion(employee_id)
      exclusion = @period.pay_period_excluded_employees.find_by(employee_id: employee_id)
      return unless exclusion

      managed = PayrollImportRecord.where(pay_period_id: @period.id, status: "applied").any? do |record|
        record.raw_data.to_h.fetch("client_change_decisions", []).any? do |decision|
          decision["decision"] == "no_pay" && decision["employee_id"].to_s == employee_id.to_s && decision["exclusion_id"] == exclusion.id && decision["reason"] == exclusion.reason
        end
      end
      exclusion if managed
    end

    # Hours on the worksheet apart from any earlier client contribution.
    def own_hours(employee_id)
      item = @period.payroll_items.find_by(employee_id: employee_id)
      return 0.to_d unless item

      evidence = item.custom_columns_data.to_h["client_change_evidence"].to_h
      regular = evidence["kind"] == "extra_hours" ? evidence["baseline_regular_hours"].to_d : item.hours_worked.to_d
      regular + item.overtime_hours.to_d + item.holiday_hours.to_d + item.pto_hours.to_d
    end

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
      if row["standing_change_id"]
        field = PayrollStandingChange.find_by(id: row["standing_change_id"], company_id: @period.company_id)
        unless field&.active? && field.employee_id == row["employee_id"] && field.kind == row["kind"] && field.employee_wage_rate_id == row["employee_wage_rate_id"]
          return "Configured entry changed. Resolve this client change before applying."
        end
      end
      return "The employee for this client change is missing or belongs to another company." unless employee
      return "#{employee.full_name} is #{employee.status}. Resolve this client change before applying." unless employee.active?
      unless Employee.where(id: employee.id).eligible_for_period(@period.start_date, @period.end_date).exists?
        return "#{employee.full_name} is not eligible for this pay period. Resolve this client change before applying."
      end
      if @period.pay_period_excluded_employees.exists?(employee_id: employee.id) && !(row["kind"] == "owner_pay" && managed_owner_exclusion(employee.id))
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
