# frozen_string_literal: true

require "digest"

module QuickbooksHistory
  class YtdBridgePlan
    Result = Struct.new(:balances, :summary, :reconciliation, :warnings, :errors, :digest, keyword_init: true) do
      def ready? = errors.empty?
    end

    NON_TAXABLE_EARNING = BundleParser::NON_TAXABLE_EARNING_LABEL
    FICA_EXEMPT_PRETAX_DEDUCTION = BundleParser::FICA_EXEMPT_PRETAX_DEDUCTION_LABEL
    RETIREMENT_PRE_TAX = /401\s*\(?k\)?.*pre.?tax/i
    RETIREMENT_ROTH = /401\s*\(?k\)?.*after.?tax|roth/i
    INSURANCE = /insurance|health/i
    LOAN = /loan|advance/i
    TIPS = /\A(?:pay\s*tips?|reported tips?)\z/i
    def initialize(batch:)
      @batch = batch
    end

    def call
      errors = eligibility_errors
      balances = errors.empty? ? build_balances : []
      errors << "The historical archive has no employee balances to carry forward" if errors.empty? && balances.empty?
      reconciliation = reconcile_balances(balances)
      if errors.any?
        reconciliation = reconciliation.merge(
          "passed" => false,
          "errors" => (Array(reconciliation["errors"]) + [ "Historical YTD eligibility validation failed" ]).uniq
        )
      end
      errors.concat(Array(reconciliation["errors"]))
      summary = build_summary(balances)
      warnings = [
        "This bridge carries retained QuickBooks balances into future YTD calculations. It does not create, recalculate, or commit historical payroll runs."
      ] + deduction_classification_warnings(balances)
      payload = {
        "batch_id" => batch.id,
        "bundle_digest" => batch.bundle_digest,
        "balances" => balances,
        "summary" => summary,
        "reconciliation" => reconciliation,
        "warnings" => warnings,
        "errors" => errors.uniq
      }
      Result.new(
        balances: balances,
        summary: summary,
        reconciliation: reconciliation,
        warnings: warnings,
        errors: errors.uniq,
        digest: Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))
      )
    end

    private

    attr_reader :batch

    def eligibility_errors
      errors = []
      errors << "Lock the approved QuickBooks history before preparing historical YTD" unless batch.locked?
      errors << "Apply the clean-client employee setup before preparing historical YTD" unless batch.historical_client_bootstrap&.applied?
      errors << "Approve the cutover review before preparing historical YTD" unless batch.historical_import_cutover_review&.approved?
      errors << "Tax and Wage Summary reconciliation must pass before preparing historical YTD" unless batch.tax_wage_reconciliation.to_h["passed"] == true
      errors << "The client already has live pay periods; historical YTD must be activated before the first live payroll" if batch.company.pay_periods.exists?
      errors << "Every historical paycheck must be linked to its prepared employee" if batch.historical_paychecks.where(employee_id: nil).exists?
      missing_wage_base_years.each do |year|
        errors << "No Social Security wage base is configured for #{year}; add the annual tax configuration before preparing historical YTD"
      end
      errors
    end

    def build_balances
      balances = []
      current_key = nil
      rows = []
      batch.historical_paychecks.includes(:employee).find_each(
        cursor: %i[employee_id pay_date id],
        order: %i[asc asc asc],
        batch_size: 1_000
      ) do |row|
        key = [ row.employee_id, row.pay_date.year ]
        if current_key && key != current_key
          balances << build_balance(current_key.fetch(0), current_key.fetch(1), rows)
          rows = []
        end
        current_key = key
        rows << row
      end
      balances << build_balance(current_key.fetch(0), current_key.fetch(1), rows) if current_key
      balances
    end

    def build_balance(employee_id, year, rows)
      employee = rows.first.employee
      wage_base = social_security_wage_base(year)
      derived_rows = rows.map do |row|
        {
          employee_key: employee_id,
          gross_pay: row.gross_pay,
          pretax_deductions: row.pretax_deductions,
          non_taxable_earnings: breakdown_sum(row.earnings_breakdown, NON_TAXABLE_EARNING),
          fica_exempt_pretax_deductions: breakdown_sum(
            row.pretax_deduction_breakdown,
            FICA_EXEMPT_PRETAX_DEDUCTION
          )
        }
      end
      wage_derivation = WageDerivation.call(
        rows: derived_rows,
        social_security_wage_base: wage_base
      )
      pretax = rows.sum(0.to_d, &:pretax_deductions).round(2)
      non_taxable = derived_rows.sum(0.to_d) { |row| row.fetch(:non_taxable_earnings) }.round(2)
      tips = rows.sum(0.to_d) { |row| breakdown_sum(row.earnings_breakdown, TIPS) }.round(2)
      social_security_taxable_total = wage_derivation.fetch(:social_security_taxable_wages)
      social_security_taxable_tips = [ tips, social_security_taxable_total ].min.round(2)
      {
        "company_id" => batch.company_id,
        "employee_id" => employee_id,
        "employee_name" => employee.full_name,
        "tax_year" => year,
        "through_pay_date" => rows.map(&:pay_date).max.iso8601,
        "through_period_end" => rows.map(&:period_end).max.iso8601,
        "gross_pay" => sum(rows, :gross_pay),
        "net_pay" => sum(rows, :net_pay),
        "federal_income_tax" => sum(rows, :federal_income_tax),
        "social_security_tax" => sum(rows, :social_security_tax),
        "medicare_tax" => sum(rows, :medicare_tax),
        # QuickBooks does not separate W-4 Step 4(c) from total FIT in this export.
        "additional_withholding" => "0.0",
        "employee_taxes" => sum(rows, :employee_taxes),
        "pretax_deductions" => pretax.to_s("F"),
        "after_tax_deductions" => sum(rows, :after_tax_deductions),
        "non_taxable_pay" => non_taxable.to_s("F"),
        "reported_tips" => tips.to_s("F"),
        "tips_paid_out" => tips.to_s("F"),
        "retirement" => component_sum(rows, :pretax_deduction_breakdown, RETIREMENT_PRE_TAX),
        "roth_retirement" => component_sum(rows, :after_tax_deduction_breakdown, RETIREMENT_ROTH),
        "insurance" => component_sum(rows, :after_tax_deduction_breakdown, INSURANCE, exclude: RETIREMENT_ROTH),
        "loans" => component_sum(rows, :after_tax_deduction_breakdown, LOAN, exclude: RETIREMENT_ROTH),
        "fit_taxable_wages" => wage_derivation.fetch(:fit_taxable_wages).to_s("F"),
        "social_security_taxable_wages" => (social_security_taxable_total - social_security_taxable_tips).round(2).to_s("F"),
        "social_security_taxable_tips" => social_security_taxable_tips.to_s("F"),
        "medicare_taxable_wages" => wage_derivation.fetch(:medicare_taxable_wages).to_s("F"),
        "employer_social_security_tax" => component_sum(rows, :employer_tax_breakdown, /\A(?:SS|Social Security(?: Employer)?)\z/i),
        "employer_medicare_tax" => component_sum(rows, :employer_tax_breakdown, /\A(?:Med|Medicare(?: Employer)?)\z/i),
        "employer_taxes" => sum(rows, :employer_taxes),
        "employer_contributions" => sum(rows, :employer_contributions),
        "source_breakdown" => source_breakdown(rows)
      }
    end

    def reconcile_balances(balances)
      checks = []
      errors = []
      balances.group_by { |row| row.fetch("tax_year") }.sort.each do |year, rows|
        expected = batch.tax_wage_reconciliation.to_h.fetch("checks", [])
                        .select { |check| check["year"].to_i == year }
                        .reject { |check| check["key"].to_s.end_with?("quarterly_rollup") }
        if expected.empty?
          errors << "#{year} has no staged Tax and Wage Summary checks; rebuild the QuickBooks preview before activating historical YTD"
          next
        end
        medicare_taxable_total = sum_hashes(rows, "medicare_taxable_wages")
        social_security_taxable = social_security_taxable_total(rows)
        bridge_values = {
          "fit_total_wages" => sum_hashes(rows, "fit_taxable_wages"),
          "fit_tax" => sum_hashes(rows, "federal_income_tax"),
          # WageDerivation equates total FICA wages with uncapped Medicare wages;
          # no separate FICA-total value is persisted on the employee bridge.
          "ss_total_wages" => medicare_taxable_total,
          "ss_excess_wages" => (medicare_taxable_total - social_security_taxable).round(2),
          "ss_taxable_wages" => social_security_taxable,
          "ss_tax" => sum_hashes(rows, "social_security_tax"),
          "employer_ss_tax" => sum_hashes(rows, "employer_social_security_tax"),
          "medicare_wages" => medicare_taxable_total,
          "medicare_tax" => sum_hashes(rows, "medicare_tax"),
          "employer_medicare_tax" => sum_hashes(rows, "employer_medicare_tax")
        }
        expected.each do |source_check|
          key = source_check["key"].to_s
          actual = bridge_values[key]
          source_amount = source_check["source_amount"]
          if actual.nil? || source_amount.nil?
            label = source_check["label"].presence || key.presence || "unknown tax-and-wage check"
            checks << source_check.slice("key", "label", "source_amount").merge(
              "year" => year,
              "bridge_amount" => actual&.to_s("F"),
              "passed" => false
            )
            errors << if actual.nil?
              "#{year} #{label} is not modeled by the historical YTD bridge; extend the bridge before activating historical YTD"
            else
              "#{year} #{label} has no source amount in the staged Tax and Wage Summary evidence; rebuild the QuickBooks preview"
            end
            next
          end

          passed = actual == BigDecimal(source_amount.to_s)
          checks << source_check.slice("key", "label", "source_amount").merge(
            "year" => year,
            "bridge_amount" => actual.to_s("F"),
            "passed" => passed
          )
          errors << "#{year} #{source_check['label'].presence || key} does not reconcile after employee allocation" unless passed
        end
        staged_keys = expected.map { |source_check| source_check["key"].to_s }
        (bridge_values.keys - staged_keys).sort.each do |key|
          checks << {
            "key" => key,
            "label" => key.humanize,
            "year" => year,
            "source_amount" => nil,
            "bridge_amount" => bridge_values.fetch(key).to_s("F"),
            "passed" => false
          }
          errors << "#{year} staged Tax and Wage Summary evidence does not cover #{key}; rebuild the QuickBooks preview before activating historical YTD"
        end
      end
      { "passed" => errors.empty?, "checks" => checks, "errors" => errors }
    end

    def build_summary(balances)
      last_pay_date = balances.map { |row| Date.iso8601(row.fetch("through_pay_date")) }.max ||
        batch.historical_paychecks.maximum(:pay_date)
      last_period_end = balances.map { |row| Date.iso8601(row.fetch("through_period_end")) }.max ||
        batch.historical_paychecks.maximum(:period_end)
      {
        "employee_count" => balances.map { |row| row.fetch("employee_id") }.uniq.size,
        "balance_count" => balances.size,
        "tax_years" => balances.pluck("tax_year").uniq.sort,
        "through_pay_date" => last_pay_date&.iso8601,
        "through_period_end" => last_period_end&.iso8601,
        "gross_pay" => sum_hashes(balances, "gross_pay").to_s("F"),
        "net_pay" => sum_hashes(balances, "net_pay").to_s("F")
      }
    end

    def sum(rows, field)
      rows.sum(0.to_d) { |row| row.public_send(field).to_d }.round(2).to_s("F")
    end

    def component_sum(rows, field, pattern, exclude: nil)
      rows.sum(0.to_d) do |row|
        Array(row.public_send(field)).sum(0.to_d) do |entry|
          label = entry.fetch("label")
          label.match?(pattern) && (exclude.nil? || !label.match?(exclude)) ? BigDecimal(entry.fetch("amount").to_s) : 0.to_d
        end
      end.round(2).to_s("F")
    end

    def breakdown_sum(entries, pattern)
      Array(entries).sum(0.to_d) do |entry|
        entry.fetch("label").match?(pattern) ? BigDecimal(entry.fetch("amount").to_s) : 0.to_d
      end
    end

    def source_breakdown(rows)
      %i[
        earnings_breakdown pretax_deduction_breakdown after_tax_deduction_breakdown
        employee_tax_breakdown employer_tax_breakdown employer_contribution_breakdown
      ].to_h do |field|
        totals = Hash.new(0.to_d)
        rows.each do |row|
          Array(row.public_send(field)).each { |entry| totals[entry.fetch("label")] += BigDecimal(entry.fetch("amount").to_s) }
        end
        [ field.to_s, totals.sort.to_h.transform_values { |amount| amount.round(2).to_s("F") } ]
      end
    end

    def deduction_classification_warnings(balances)
      fields = {
        "pretax_deduction_breakdown" => { "pre-tax retirement" => RETIREMENT_PRE_TAX },
        "after_tax_deduction_breakdown" => {
          "Roth retirement" => RETIREMENT_ROTH,
          "insurance" => INSURANCE,
          "loan or advance" => LOAN
        }
      }
      warnings = fields.flat_map do |field, buckets|
        labels = balances.flat_map { |balance| balance.dig("source_breakdown", field).to_h.keys }.uniq.sort
        labels.filter_map do |label|
          matches = buckets.filter_map { |name, pattern| name if label.match?(pattern) }
          if matches.empty?
            "QuickBooks deduction label “#{label}” remains in the #{field.humanize.downcase} total but is not assigned to a specialized YTD bucket."
          elsif matches.many?
            "QuickBooks deduction label “#{label}” matches more than one historical YTD bucket (#{matches.join(', ')}); review the source classification."
          end
        end
      end
      if balances.any? { |balance| BigDecimal(balance.fetch("reported_tips").to_s).positive? }
        warnings << "QuickBooks tip earnings are carried as reported tips, but the historical export does not distinguish tips paid out separately. Confirm the tip treatment before activation."
      end
      warnings
    end

    def sum_hashes(rows, field)
      rows.sum(0.to_d) { |row| BigDecimal(row.fetch(field).to_s) }.round(2)
    end

    def social_security_taxable_total(rows)
      sum_hashes(rows, "social_security_taxable_wages") + sum_hashes(rows, "social_security_taxable_tips")
    end

    def social_security_wage_base(year)
      AnnualTaxConfig.historical_ss_wage_base(year)
    end

    def missing_wage_base_years
      batch.historical_paychecks.distinct.pluck(:pay_date).map(&:year).uniq.sort.reject do |year|
        social_security_wage_base(year)
      end
    end

    def canonical(value)
      CanonicalJson.normalize(value)
    end
  end
end
