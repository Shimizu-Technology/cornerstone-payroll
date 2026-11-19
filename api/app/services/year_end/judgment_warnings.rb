# frozen_string_literal: true

require "digest"

module YearEnd
  # Turns the W-2GU report's review warnings into year-end checklist items.
  #
  # A warning whose data can be corrected (negative annual Box 12 amounts, a
  # tipped employee without a Treasury occupation code) blocks until it is
  # fixed. A warning that needs a reviewer's judgment (unclassified tips or
  # overtime, legacy tax bases, opening balances with no paycheck dates) needs
  # an explicit, audited acknowledgement. An acknowledgement counts only while
  # its digest matches the warning computed from current data.
  class JudgmentWarnings
    DEFINITIONS = {
      "negative_box12_amounts" => {
        kind: "blocker",
        title: "Negative annual tips or overtime",
        explanation: "A W-2 cannot report a negative Box 12 TP or TT amount. Correct the payroll for these employees before filing."
      },
      "tipped_occupation_code_missing" => {
        kind: "blocker",
        title: "Tipped employees without an occupation code",
        explanation: "Box 14b needs a Treasury tipped occupation code for each employee with tips. Add the code on each employee's profile."
      },
      "tip_classification_unreviewed" => {
        kind: "acknowledge",
        title: "Tips without 2026 cash-tip classification",
        explanation: "These employees have tips that were not classified as cash tips (for example QuickBooks-era history), so Box 12 TP may be understated. Review the tips and record what you confirmed."
      },
      "qualified_overtime_unreviewed" => {
        kind: "acknowledge",
        title: "Overtime without qualified-overtime amounts",
        explanation: "These employees have overtime with no stored qualified-overtime amount, so Box 12 TT may be understated. Review the overtime and record what you confirmed."
      },
      "box14b_more_than_two_codes" => {
        kind: "acknowledge",
        title: "More than two tipped occupation codes",
        explanation: "Box 14b holds two codes. The W-2 will show the first two codes in order. Confirm that is right for these employees."
      },
      "legacy_tax_bases" => {
        kind: "acknowledge",
        title: "Older payroll without stored taxable wages",
        explanation: "Some payroll rows were committed before taxable wage bases were stored, so their W-2 amounts use a compatibility calculation. Confirm the reconciliation above ties out for these employees."
      },
      "legacy_employer_benefit_unclassified" => {
        kind: "acknowledge",
        title: "Employer benefit history not yet classified",
        explanation: PayrollReportComponentReview::MESSAGE
      },
      "form_941_liability_residual" => {
        kind: "acknowledge",
        title: "941 tax liability differs from recorded taxes",
        explanation: "After the line 7 rounding adjustment, the recorded employee and employer Social Security and Medicare taxes still differ from line 6 on these quarters' 941s. This is usually employer rounding on each paycheck. Confirm the employer amounts and record what you checked."
      },
      "opening_balances_compare_filed_returns" => {
        kind: "acknowledge",
        title: "Opening balances to compare with filed returns",
        explanation: "Opening balances cover pay dates before this client's payroll started here. This app has no paychecks for them, so it cannot rebuild those quarters' 941s and W-1s. Compare the opening balance amounts in the reconciliation with the returns that were filed for those quarters."
      }
    }.freeze

    # The saved paycheck amounts and classifications each warning depends on.
    # Changing any of them (not only the item count) needs a new review.
    ITEM_EVIDENCE_FIELDS = {
      "tip_classification_unreviewed" => %w[id pay_period_id gross_pay tips reported_tips cash_tips_reported social_security_taxable_tips],
      "qualified_overtime_unreviewed" => %w[id pay_period_id gross_pay pay_rate hours_worked overtime_hours qualified_overtime_compensation],
      "legacy_tax_bases" => %w[id pay_period_id gross_pay reported_tips fit_taxable_wages social_security_taxable_wages
                               social_security_taxable_tips medicare_taxable_wages withholding_tax social_security_tax medicare_tax]
    }.freeze
    ROW_EVIDENCE_FIELDS = {
      "tip_classification_unreviewed" => %i[reported_tips_total box3_social_security_wages box7_social_security_tips box5_medicare_wages_tips],
      "qualified_overtime_unreviewed" => %i[box1_wages_tips_other_comp box3_social_security_wages box5_medicare_wages_tips],
      "legacy_tax_bases" => %i[box1_wages_tips_other_comp box2_federal_income_tax_withheld box3_social_security_wages
                               box4_social_security_tax_withheld box5_medicare_wages_tips box6_medicare_tax_withheld box7_social_security_tips]
    }.freeze

    def self.digest_for(code, evidence)
      Digest::SHA256.hexdigest(JSON.generate([ code, evidence ]))
    end

    def initialize(company:, year:, w2_report:, reconciliation: nil, acknowledgements: nil)
      @company = company
      @year = Integer(year)
      @w2_report = w2_report
      @reconciliation = reconciliation
      @acknowledgements = acknowledgements || company.year_end_acknowledgements.where(tax_year: @year).index_by(&:warning_code)
    end

    def call
      detected.map { |code, evidence| warning_payload(code, evidence) }
    end

    # Current digest by code, for validating an acknowledgement request.
    def digests
      detected.to_h { |code, evidence| [ code, self.class.digest_for(code, evidence.except(:names, :messages)) ] }
    end

    private

    attr_reader :company, :year, :w2_report, :reconciliation, :acknowledgements

    def rows
      Array(w2_report[:employees])
    end

    def tip_rules_year?
      year >= 2026
    end

    # Evidence for each code is the sorted, minimal data the reviewer saw. Any
    # new payroll for an affected employee changes it and needs a new review.
    def detected
      @detected ||= begin
        found = {}
        add(found, "negative_box12_amounts", rows.select { |row| row[:negative_box12_tp] || row[:negative_box12_tt] }) do |row|
          [ row[:employee_id], row[:negative_box12_tp], row[:negative_box12_tt] ]
        end
        if tip_rules_year?
          add(found, "tipped_occupation_code_missing", rows.select { |row| row[:reported_tips_total].to_d.positive? && row[:box14b_tipped_occupation_codes].blank? }) do |row|
            [ row[:employee_id] ]
          end
          add(found, "tip_classification_unreviewed", rows.select { |row| row[:missing_tip_classification] }) do |row|
            [ row[:employee_id], money(box12_amount(row, "TP")), *source_evidence("tip_classification_unreviewed", row) ]
          end
          add(found, "qualified_overtime_unreviewed", rows.select { |row| row[:missing_qualified_overtime] }) do |row|
            [ row[:employee_id], money(box12_amount(row, "TT")), *source_evidence("qualified_overtime_unreviewed", row) ]
          end
          add(found, "box14b_more_than_two_codes", rows.select { |row| row[:excess_box14b_tipped_occupation_codes] }) do |row|
            [ row[:employee_id], Array(row[:box14b_tipped_occupation_codes]) ]
          end
        end
        add(found, "legacy_tax_bases", rows.select { |row| row[:missing_committed_tax_bases] }) do |row|
          [ row[:employee_id], *source_evidence("legacy_tax_bases", row) ]
        end
        add_review_warnings(found)
        add_form_941_residuals(found)
        add_opening_balances(found)
        found
      end
    end

    def add(found, code, affected)
      return if affected.empty?

      found[code] = {
        employees: affected.sort_by { |row| row[:employee_id] }.map { |row| yield(row) },
        names: affected.to_h { |row| [ row[:employee_id], row[:employee_name] ] }
      }
    end

    def add_review_warnings(found)
      warnings = Array(w2_report[:review_warnings]).select { |warning| warning[:code] == PayrollReportComponentReview::CODE }
      return if warnings.empty?

      names = rows.to_h { |row| [ row[:employee_id], row[:employee_name] ] }
      ids = warnings.map { |warning| warning[:employee_id] }.compact.uniq.sort
      components = benefit_component_evidence(warnings.filter_map { |warning| warning[:payroll_item_id] })
      found["legacy_employer_benefit_unclassified"] = {
        employees: ids.map do |id|
          item_ids = warnings.select { |warning| warning[:employee_id] == id }.filter_map { |warning| warning[:payroll_item_id] }.uniq.sort
          [ id, item_ids.map { |item_id| [ item_id, components.fetch(item_id, []) ] } ]
        end,
        names: ids.index_with { |id| names[id] }
      }
    end

    def add_form_941_residuals(found)
      residuals = Array(reconciliation&.dig(:form_941_reviews)).select { |review| review[:status] == "residual" }
      return if residuals.empty?

      found["form_941_liability_residual"] = {
        employees: [],
        names: {},
        quarters: residuals.map { |review| [ review[:quarter], money(review[:recorded_liability_residual]), money(review[:employee_difference]) ] },
        messages: residuals.map { |review| review[:message] }
      }
    end

    # Per employee: the W-2 amounts the reviewer saw plus a hash of every saved
    # paycheck field the warning depends on.
    def source_evidence(code, row)
      fields = ROW_EVIDENCE_FIELDS.fetch(code).map { |field| money(row[field]) }
      fields + [ payroll_item_count(row), item_digests(code)[row[:employee_id]] ]
    end

    def item_digests(code)
      @item_digests ||= {}
      @item_digests[code] ||= begin
        columns = ITEM_EVIDENCE_FIELDS.fetch(code)
        W2PayrollItems.scope(company.id, year).where(employee_id: rows.map { |row| row[:employee_id] })
          .order(:employee_id, :id).pluck(:employee_id, *columns.map { |column| "payroll_items.#{column}" })
          .group_by(&:first)
          .transform_values { |values| Digest::SHA256.hexdigest(JSON.generate(values.map { |value| value.drop(1).map(&:to_s) })) }
      end
    end

    # The saved employer fields and deductions (with their classifications)
    # on each flagged paycheck.
    def benefit_component_evidence(item_ids)
      return {} if item_ids.empty?

      fields = PayrollItemFieldEntry.where(payroll_item_id: item_ids).order(:id)
        .pluck(:payroll_item_id, :id, :payroll_field_definition_id, :label, :kind, :category, :tax_treatment,
               :reporting_group, :employer_paid, :employee_paid, :active, :amount, :metadata)
      deductions = PayrollItemDeduction.joins(:deduction_type).where(payroll_item_id: item_ids).order(:id)
        .pluck(:payroll_item_id, :id, :deduction_type_id, :label, :category, :reporting_group, :amount,
               "deduction_types.category", "deduction_types.sub_category", "deduction_types.reporting_group")
      (fields.map { |entry| [ "field", *entry ] } + deductions.map { |entry| [ "deduction", *entry ] })
        .group_by(&:second)
        .transform_values { |entries| Digest::SHA256.hexdigest(JSON.generate(entries.map { |entry| entry.map(&:to_s) })) }
    end

    def add_opening_balances(found)
      return unless reconciliation&.dig(:opening_balances, :present)

      amounts = Array(reconciliation[:lines]).map { |line| [ line[:key], money(line[:opening_balances]) ] }
      found["opening_balances_compare_filed_returns"] = {
        employees: [],
        names: {},
        amounts: amounts,
        period: reconciliation[:opening_balances].values_at(:first_pay_date, :last_pay_date)
      }
    end

    def warning_payload(code, evidence)
      definition = DEFINITIONS.fetch(code)
      digest = self.class.digest_for(code, evidence.except(:names, :messages))
      acknowledgement = acknowledgements[code]
      current = acknowledgement && acknowledgement.warning_digest == digest
      status = if definition[:kind] == "blocker"
        "blocked"
      elsif current
        "reviewed"
      else
        "needs_review"
      end
      ids = evidence[:employees].map(&:first)

      {
        code: code,
        kind: definition[:kind],
        title: definition[:title],
        explanation: definition[:explanation],
        status: status,
        digest: digest,
        period: evidence[:period],
        details: evidence[:messages] || [],
        employees: ids.map do |id|
          { employee_id: id, name: evidence[:names][id], edit_path: "/companies/#{company.id}/employees/#{id}" }
        end,
        acknowledgement: definition[:kind] == "acknowledge" && acknowledgement ? acknowledgement.payload : nil,
        acknowledgement_stale: definition[:kind] == "acknowledge" && acknowledgement.present? && !current
      }
    end

    def box12_amount(row, code)
      Array(row[:box12]).select { |entry| entry[:code] == code }.sum(0.to_d) { |entry| entry[:amount].to_d }
    end

    def payroll_item_count(row)
      row.dig(:source_summary, :cornerstone_payroll_item_count).to_i
    end

    def money(value)
      BigDecimal(value.to_s.presence || "0").round(2).to_s("F")
    end
  end
end
