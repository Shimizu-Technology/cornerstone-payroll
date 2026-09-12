# frozen_string_literal: true

module PayrollImport
  # Orchestrates the payroll import process:
  # 1. Parse Revel PDF (hours only; source pay values are never imported)
  # 2. Parse Excel template (tips, loans, and explicit per-payroll bonuses)
  # 3. Match names to Employee records
  # 4. Return preview data
  # 5. Apply import to create/update PayrollItems
  class ImportService
    attr_reader :pay_period, :company_id, :actor

    def initialize(pay_period, actor: nil)
      @pay_period = pay_period
      @company_id = pay_period.company_id
      @actor = actor
    end

    # Preview: parse files and match names without persisting
    # @param pdf_file [File, nil] Revel POS PDF
    # @param excel_file [File, nil] Tips/Loans Excel
    # @param pdf_records [Array<Hash>, nil] pre-parsed PDF rows (optional)
    # @param excel_records [Array<Hash>, nil] pre-parsed Excel rows (optional)
    # @return [Hash] preview data with matched employees
    def preview(pdf_file: nil, excel_file: nil, pdf_records: nil, excel_records: nil)
      employees = Employee.active.where(company_id: company_id)
      employees_by_id = employees.index_by(&:id)
      matcher = NameMatcher.new(employees)

      pdf_records ||= (pdf_file ? RevelPdfParser.parse_file(pdf_file) : [])
      excel_records ||= (excel_file ? LoanTipExcelParser.parse_file(excel_file) : [])

      # Pre-match all Excel records to employee IDs using the fuzzy NameMatcher
      # so tips/loans are correctly linked even when names have middle initials or typos.
      excel_lookup = build_excel_lookup(excel_records, matcher, employees_by_id)
      excel_by_employee_id = excel_lookup.fetch(:by_employee_id)

      matched = []
      unmatched_pdf_names = []
      low_confidence_matches = excel_lookup.fetch(:low_confidence_matches)

      pdf_records.each do |pdf_row|
        match = matcher.match_pdf_name(pdf_row[:employee_name])

        if match
          employee = employees_by_id[match[:employee_id]]
          next unless employee

          excel_data = excel_by_employee_id[employee.id]
          matched << build_preview_row(pdf_row, employee, match, excel_data)
          if low_confidence?(match)
            low_confidence_matches << build_match_review("Revel hours", pdf_row[:employee_name], employee, match)
          end
        else
          unmatched_pdf_names << pdf_row[:employee_name]
        end
      end

      # Handle Excel-only employees (have tips/loans but no PDF hours)
      excel_by_employee_id.each do |emp_id, excel_data|
        next if matched.any? { |m| m[:employee_id] == emp_id }

        employee = employees_by_id[emp_id]
        next unless employee

        excel_match = { employee_id: emp_id, confidence: 1.0, matched_name: employee.full_name }
        matched << build_preview_row(nil, employee, excel_match, excel_data)
      end

      duplicate_employee_matches = matched
        .group_by { |row| row[:employee_id] }
        .filter_map do |employee_id, rows|
          next unless rows.many?

          {
            employee_id: employee_id,
            employee_name: rows.first[:employee_name],
            source_names: rows.filter_map { |row| row[:pdf_employee_name] }.uniq
          }
        end

      unmatched_excel_names = excel_lookup.fetch(:unmatched_names)

      {
        matched: matched,
        unmatched_pdf_names: unmatched_pdf_names,
        unmatched_excel_names: unmatched_excel_names,
        duplicate_employee_matches: duplicate_employee_matches,
        low_confidence_matches: low_confidence_matches.uniq,
        pdf_count: pdf_records.length,
        excel_count: excel_records.length,
        matched_count: matched.length,
        can_apply: unmatched_pdf_names.empty? && unmatched_excel_names.empty? && duplicate_employee_matches.empty? &&
          matched.none? { |row| Array(row[:loan_reconciliation_errors]).any? }
      }
    end

    # Apply: persist matched import data to PayrollItems
    # @param matched [Array<Hash>] preview rows to apply
    # @param force_overwrite [Boolean] allow overwriting non-import existing payroll items
    # @param tips_paid_out_from_tips [Boolean] when true, imported tips were already paid daily and should offset the check
    # @return [Hash] results with success/error counts
    def apply!(matched:, force_overwrite: false, tips_paid_out_from_tips: false)
      pay_period.with_lock do
        apply_locked!(
          matched: matched,
          force_overwrite: force_overwrite,
          tips_paid_out_from_tips: tips_paid_out_from_tips
        )
      end
    end

    private

    def apply_locked!(matched:, force_overwrite:, tips_paid_out_from_tips:)
      raise ArgumentError, "Cannot apply to a non-editable pay period" unless pay_period.can_edit?

      results = { success: [], skipped: [], errors: [] }

      employee_ids = matched.map { |row| row[:employee_id] }.compact.uniq
      employees_by_id = Employee.where(id: employee_ids, company_id: company_id).index_by(&:id)
      rows_by_employee_id = matched.index_by { |row| row[:employee_id].to_i }
      excluded_employee_ids = pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set

      # Fail before writing any source rows. A recurring bonus cannot stand in
      # for the period pay of a variable-salary employee on a regular run.
      missing_salary_names = employees_by_id.values.filter_map do |employee|
        next if excluded_employee_ids.include?(employee.id)
        next unless employee.variable_salary? && pay_period.includes_base_salary?

        item = pay_period.payroll_items.find_by(employee_id: employee.id) || PayrollItem.new(pay_period: pay_period, employee: employee)
        source_period_pay = decimal_or_zero(rows_by_employee_id.dig(employee.id, :period_pay))
        employee.full_name if source_period_pay <= 0 && existing_manual_period_pay(item).blank?
      end
      if missing_salary_names.any?
        raise ArgumentError, "Enter Pay this period in the payroll worksheet for #{missing_salary_names.join(', ')}, then preview the import again. Nothing has been imported."
      end

      ActiveRecord::Base.transaction(requires_new: true) do
        matched.each do |row|
          employee_id = row[:employee_id]
          if excluded_employee_ids.include?(employee_id)
            results[:skipped] << {
              employee_id: employee_id,
              name: employees_by_id[employee_id]&.full_name,
              reason: "Excluded from this pay period"
            }
            next
          end

          employee = employees_by_id[employee_id]
          next unless employee

          payroll_item = pay_period.payroll_items.find_or_initialize_by(employee_id: employee.id)

          # Prevent silent overwrite of manual/non-import entries unless explicitly forced.
          if payroll_item.persisted? && payroll_item.import_source != "mosa_revel" && !force_overwrite
            results[:errors] << {
              employee_id: employee.id,
              name: employee.full_name,
              error: "Payroll item already exists (manual/non-import). Pass force_overwrite to replace."
            }
            next
          end

          begin
            PayrollItem.transaction(requires_new: true) do
              # Set employment info
              payroll_item.employment_type = employee.employment_type
              payroll_item.pay_rate = employee.pay_rate
              payroll_item.additional_withholding = employee.additional_withholding.to_f if payroll_item.new_record?
              apply_period_pay!(payroll_item, employee, row)

              # Set hours from PDF
              payroll_item.hours_worked = row[:regular_hours].to_f if row[:regular_hours]
              payroll_item.overtime_hours = row[:overtime_hours].to_f if row[:overtime_hours]

              # Set tips from Excel — reported_tips is the taxable tip source of truth.
              # Legacy `tips` is cleared to prevent historical double counting.
              payroll_item.reported_tips = row[:total_tips].to_f
              row_tips_paid_out = if row[:tips_already_paid].nil?
                tips_paid_out_from_tips
              else
                row[:tips_already_paid]
              end
              payroll_item.tips_paid_out = row_tips_paid_out ? row[:total_tips].to_f : 0.0
              payroll_item.tips = 0.0  # Reset to avoid double-counting
              payroll_item.tip_pool = row[:tip_pool] if row[:tip_pool]
              payroll_item.loan_deduction = row[:loan_deduction].to_f if row[:loan_deduction]
              PayrollBonusInput.import!(payroll_item, row[:bonus])
              payroll_item.import_source = "mosa_revel"
              payroll_item.sync_default_payroll_adjustments!(employee)
              apply_imported_components!(payroll_item, row[:payroll_components])

              # Calculate payroll (taxes, deductions, net pay)
              payroll_item.calculate!
            end

            results[:success] << { employee_id: employee.id, name: employee.full_name }
          rescue ActiveRecord::Rollback
            raise
          rescue ActiveRecord::StatementInvalid
            # Let DB-level transaction errors abort cleanly; avoid PG::InFailedSqlTransaction cascades.
            raise
          rescue StandardError => e
            results[:errors] << { employee_id: employee.id, name: employee&.full_name, error: e.message }
          end
        end
      end

      # The parent pay-period lock owns the outer transaction. Keep the status
      # transition in that boundary so item writes cannot survive a failed state
      # transition or race a commit.
      if results[:errors].empty? && results[:success].any?
        pay_period.update!(
          status: "calculated",
          calculated_at: Time.current,
          calculated_by_id: actor&.id,
          approved_at: nil,
          approved_by_id: nil,
          intake_stale_at: nil,
          intake_stale_reason: nil,
          intake_stale_session: nil
        )
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: actor).issue!
      end

      results
    end

    def build_excel_lookup(excel_records, matcher, employees_by_id)
      lookup = {}
      unmatched_names = []
      low_confidence_matches = []

      excel_records.each do |row|
        match = if row[:employee_id].present?
          employee = employees_by_id[row[:employee_id].to_i]
          employee && { employee_id: employee.id, confidence: 1.0, matched_name: employee.full_name, method: "employee_id" }
        else
          matcher.match_excel_name(row[:last_name], row[:first_name])
        end
        source_name = [ row[:first_name], row[:last_name] ].compact.join(" ").strip
        source_name = row[:employee_name].presence || source_name

        unless match
          unmatched_names << source_name
          next
        end

        employee = employees_by_id[match[:employee_id]]
        if employee && low_confidence?(match)
          low_confidence_matches << build_match_review("Tips/loans workbook", source_name, employee, match)
        end

        existing = lookup[match[:employee_id]]
        lookup[match[:employee_id]] = existing ? merge_excel_rows(existing, row) : row.dup
      end

      {
        by_employee_id: lookup,
        unmatched_names: unmatched_names.uniq,
        low_confidence_matches: low_confidence_matches
      }
    end

    def merge_excel_rows(existing, incoming)
      if existing.key?(:bonus) && incoming.key?(:bonus)
        raise ArgumentError, "Multiple bonus rows matched the same employee. Combine them into one approved amount."
      end

      {
        **(existing.key?(:bonus) ? { bonus: existing[:bonus] } : incoming.slice(:bonus)),
        last_name: existing[:last_name] || incoming[:last_name],
        first_name: existing[:first_name] || incoming[:first_name],
        total_tips: existing[:total_tips].to_f + incoming[:total_tips].to_f,
        tips_boh: existing[:tips_boh].to_f + incoming[:tips_boh].to_f,
        tips_foh: existing[:tips_foh].to_f + incoming[:tips_foh].to_f,
        loan_deduction: existing[:loan_deduction].to_f + incoming[:loan_deduction].to_f,
        one_payroll_deduction: existing[:one_payroll_deduction].to_f + incoming[:one_payroll_deduction].to_f,
        recurring_loan_deduction: existing[:recurring_loan_deduction].to_f + incoming[:recurring_loan_deduction].to_f,
        installment_beginning_balance: [ existing[:installment_beginning_balance].to_f, incoming[:installment_beginning_balance].to_f ].max,
        installment_new_amount: existing[:installment_new_amount].to_f + incoming[:installment_new_amount].to_f,
        installment_payment: existing[:installment_payment].to_f + incoming[:installment_payment].to_f,
        installment_estimated_ending_balance: [ existing[:installment_estimated_ending_balance].to_f, incoming[:installment_estimated_ending_balance].to_f ].max,
        tips_already_paid: merge_optional_boolean(existing[:tips_already_paid], incoming[:tips_already_paid]),
        tip_pool: merge_tip_pool(existing[:tip_pool], incoming[:tip_pool]),
        period_pay: merge_period_pay(existing[:period_pay], incoming[:period_pay]),
        period_pay_evidence: existing[:period_pay_evidence] || incoming[:period_pay_evidence],
        payroll_components: merge_payroll_components(existing[:payroll_components], incoming[:payroll_components])
      }
    end

    def merge_optional_boolean(existing_value, incoming_value)
      values = [ existing_value, incoming_value ].compact.uniq
      raise ArgumentError, "Conflicting tip payout answers matched the same employee." if values.many?

      values.first
    end

    def merge_tip_pool(existing_pool, incoming_pool)
      return incoming_pool if existing_pool.blank?
      return existing_pool if incoming_pool.blank? || incoming_pool == existing_pool

      "mixed"
    end

    def merge_period_pay(existing_value, incoming_value)
      values = [ existing_value, incoming_value ].compact.map { |value| decimal_or_zero(value) }.uniq
      raise ArgumentError, "Multiple period-pay rows matched the same employee. Keep one explicit amount per person." if values.many?

      values.first
    end

    def merge_payroll_components(existing, incoming)
      components = Array(existing) + Array(incoming)
      duplicates = components.group_by do |component|
        data = component.to_h.with_indifferent_access
        [ data[:label].to_s.downcase, data[:tax_treatment].to_s ]
      end.select { |_key, rows| rows.many? }
      raise ArgumentError, "Multiple one-time component rows matched the same employee and label." if duplicates.any?

      components
    end

    def build_preview_row(pdf_row, employee, match, excel_data)
      existing_item = pay_period.payroll_items.find_by(employee_id: employee.id)
      loan_reconciliation = LoanReconciliation.new(
        employee: employee,
        pay_date: pay_period.pay_date,
        source_row: excel_data || {}
      ).call
      source_bonus = excel_data&.dig(:bonus)
      retained_bonus = existing_item && PayrollBonusInput.manual?(existing_item)
      row = {
        bonus: source_bonus,
        current_bonus: existing_item&.bonus&.to_f || 0.0,
        effective_bonus: retained_bonus || source_bonus.nil? ? (existing_item&.bonus&.to_f || 0.0) : source_bonus.to_f,
        bonus_keeps_manual: !!retained_bonus,
        employee_id: employee.id,
        employee_name: employee.full_name,
        employment_type: employee.employment_type,
        period_pay_required: employee.variable_salary? && pay_period.includes_base_salary?,
        # Keep the authoritative workbook value and its evidence in the
        # server-retained preview. `current_period_pay` is presentation data;
        # apply! must receive the original amount and proof after the browser
        # review round trip.
        period_pay: excel_data&.dig(:period_pay),
        period_pay_evidence: excel_data&.dig(:period_pay_evidence),
        current_period_pay: source_period_pay(excel_data) || existing_manual_period_pay(existing_item),
        period_pay_source: source_period_pay(excel_data) ? "change_workbook" : (existing_manual_period_pay(existing_item).present? ? "payroll_worksheet" : nil),
        period_pay_missing: period_pay_missing?(employee, existing_item, excel_data),
        overwrite_required: existing_item.present? && existing_item.import_source != "mosa_revel",
        pay_rate: employee.pay_rate.to_f,
        confidence: match[:confidence],
        matched_name: match[:matched_name],
        # PDF data
        regular_hours: pdf_row&.dig(:regular_hours) || 0.0,
        overtime_hours: pdf_row&.dig(:overtime_hours) || 0.0,
        total_hours: pdf_row&.dig(:total_hours) || 0.0,
        pdf_employee_name: pdf_row&.dig(:employee_name),
        # Excel data
        total_tips: excel_data&.dig(:total_tips) || 0.0,
        tips_boh: excel_data&.dig(:tips_boh) || 0.0,
        tips_foh: excel_data&.dig(:tips_foh) || 0.0,
        tips_already_paid: excel_data&.dig(:tips_already_paid),
        tip_pool: excel_data&.dig(:tip_pool),
        loan_deduction: loan_reconciliation.fetch(:direct_loan_deduction).to_f,
        one_payroll_deduction: excel_data&.dig(:one_payroll_deduction) || 0.0,
        recurring_loan_deduction: excel_data&.dig(:recurring_loan_deduction) || 0.0,
        installment_beginning_balance: excel_data&.dig(:installment_beginning_balance) || 0.0,
        installment_new_amount: excel_data&.dig(:installment_new_amount) || 0.0,
        installment_payment: excel_data&.dig(:installment_payment) || 0.0,
        installment_estimated_ending_balance: excel_data&.dig(:installment_estimated_ending_balance) || 0.0,
        loan_reconciliation_matches: loan_reconciliation.fetch(:matches),
        loan_reconciliation_errors: loan_reconciliation.fetch(:errors),
        loan_reconciliation_warnings: loan_reconciliation.fetch(:warnings),
        payroll_components: Array(excel_data&.dig(:payroll_components))
      }

      row
    end

    def source_period_pay(excel_data)
      value = excel_data&.dig(:period_pay)
      decimal_or_zero(value).positive? ? decimal_or_zero(value).to_s("F") : nil
    end

    def period_pay_missing?(employee, existing_item, excel_data)
      return false unless employee.variable_salary? && pay_period.includes_base_salary?

      source_period_pay(excel_data).blank? &&
        existing_manual_period_pay(existing_item).blank?
    end

    def existing_manual_period_pay(payroll_item)
      return if payroll_item.blank? || payroll_item.salary_override.to_d <= 0

      evidence = payroll_item.custom_columns_data.to_h["period_pay_evidence"].to_h
      return if evidence["source_type"] == "mosa_change_workbook"

      payroll_item.salary_override.to_d.to_s("F")
    end

    def apply_period_pay!(payroll_item, employee, row)
      amount = decimal_or_zero(row[:period_pay])
      if amount.zero?
        evidence = payroll_item.custom_columns_data.to_h["period_pay_evidence"].to_h
        if evidence["source_type"] == "mosa_change_workbook"
          payroll_item.salary_override = nil
          payroll_item.clear_imported_period_pay_evidence!
        end
        return
      end
      raise ArgumentError, "Pay this employee must be a positive amount." unless amount.positive?
      raise ArgumentError, "Pay this employee is only allowed for variable-pay salary employees." unless employee.variable_salary?

      evidence = row[:period_pay_evidence].to_h.deep_symbolize_keys
      raise ArgumentError, "Pay this employee must confirm THIS EMPLOYEE ONLY." unless evidence[:scope] == "THIS EMPLOYEE ONLY"
      raise ArgumentError, "Pay this employee requires a source or reason." if evidence[:source].to_s.strip.blank?
      unless iso_date(evidence[:effective_pay_date]) == pay_period.pay_date
        raise ArgumentError, "Pay this employee must use this payroll's pay date."
      end

      payroll_item.salary_override = amount
      data = payroll_item.custom_columns_data.is_a?(Hash) ? payroll_item.custom_columns_data.deep_dup : {}
      data["period_pay_evidence"] = evidence.deep_stringify_keys.merge(
        "amount" => amount.to_s("F"),
        "employee_id" => employee.id,
        "employee_name" => employee.full_name,
        "source_type" => "mosa_change_workbook"
      )
      payroll_item.custom_columns_data = data
    end

    def apply_imported_components!(payroll_item, components)
      normalized = Array(components).map { |component| validate_component!(component) }
      payroll_item.payroll_item_field_entries.select { |entry| entry.source == "import" }.each(&:destroy!)
      normalized.each do |component|
        payroll_item.payroll_item_field_entries.build(
          label: component.fetch(:label),
          kind: component.fetch(:kind),
          tax_treatment: component.fetch(:tax_treatment),
          category: component.fetch(:category),
          amount: component.fetch(:amount),
          employee_paid: component.fetch(:kind) != "employer_contribution",
          employer_paid: component.fetch(:kind) == "employer_contribution",
          reporting_group: component[:reporting_group],
          source: "import",
          notes: component[:notes],
          metadata: component.except(:label, :kind, :tax_treatment, :category, :amount, :reporting_group, :notes)
        )
      end
    end

    def validate_component!(component)
      data = component.to_h.with_indifferent_access
      amount = decimal_or_zero(data[:amount])
      kind = data[:kind].to_s
      treatment = data[:tax_treatment].to_s
      category = data[:category].to_s
      component_type = data[:component_type].to_s
      rule = PayrollImport::LoanTipExcelParser::GENERATED_COMPONENT_TYPES[component_type]
      raise ArgumentError, "Imported component label is required." if data[:label].to_s.strip.blank?
      raise ArgumentError, "Imported component amount must be positive." unless amount.positive?
      raise ArgumentError, "Imported component type is invalid." unless rule
      raise ArgumentError, "Imported component kind is invalid." unless PayrollFieldDefinition::KINDS.include?(kind)
      raise ArgumentError, "Imported component tax treatment is invalid." unless PayrollFieldDefinition::TAX_TREATMENTS.include?(treatment)
      raise ArgumentError, "Imported component category is invalid." unless PayrollFieldDefinition::CATEGORIES.include?(category)
      unless kind == rule.fetch(:kind) && treatment == rule.fetch(:tax_treatment)
        raise ArgumentError, "Imported component type and tax treatment conflict."
      end
      raise ArgumentError, "Loan and retirement changes must use their dedicated Cornerstone setup." if category.in?(%w[loan retirement])
      raise ArgumentError, "Imported component source or reason is required." if data[:source].to_s.strip.blank?
      unless iso_date(data[:effective_pay_date]) == pay_period.pay_date
        raise ArgumentError, "Imported components must use this payroll's pay date."
      end
      if kind.in?(%w[deduction employer_contribution]) && data[:payee_name].to_s.strip.blank?
        raise ArgumentError, "Imported deduction and employer contribution components require a payee."
      end
      expected_treatments = {
        "addition" => %w[taxable_addition non_taxable_addition],
        "deduction" => %w[pre_tax_deduction post_tax_deduction],
        "employer_contribution" => %w[employer_contribution]
      }
      raise ArgumentError, "Imported component type and tax treatment conflict." unless expected_treatments.fetch(kind).include?(treatment)

      {
        label: data[:label].to_s.strip,
        amount: amount,
        kind: kind,
        tax_treatment: treatment,
        category: category,
        reporting_group: PayrollReportingGroups.normalize(data[:reporting_group]),
        payee_name: data[:payee_name].to_s.strip.presence,
        effective_pay_date: data[:effective_pay_date].to_s,
        source: data[:source].to_s.strip,
        notes: data[:notes].to_s.strip.presence,
        component_type: component_type
      }
    end

    def decimal_or_zero(value)
      BigDecimal(value.to_s, exception: false)&.round(2) || 0.to_d
    end

    def iso_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def low_confidence?(match)
      match[:confidence].to_f < 1.0
    end

    def build_match_review(source, source_name, employee, match)
      {
        source: source,
        source_name: source_name,
        employee_id: employee.id,
        employee_name: employee.full_name,
        confidence: match[:confidence]
      }
    end
  end
end
