# frozen_string_literal: true

module PriorProviderHistory
  class Activation
    ACKNOWLEDGEMENT = "ACTIVATE VERIFIED HISTORICAL YTD"

    def initialize(onboarding:, actor:, acknowledgement:)
      @onboarding, @actor, @acknowledgement = onboarding, actor, acknowledgement
    end

    def call
      QuickbooksHistory::ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: onboarding.company_id)
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
      onboarding.class.transaction do
        company.lock!
        onboarding.lock!
        batch.lock!
        @actor = QuickbooksHistory::ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: company.id, lock: true)
        next onboarding if onboarding.status == "active"
        raise ArgumentError, "Only converted history can be activated" unless onboarding.status == "converted"
        raise ArgumentError, "Enable historical payroll for this client before activation" unless company.historical_payroll_enabled?
        raise ArgumentError, "Resolve other payroll runs before activating the opening balances" if company.pay_periods.where.not(status: "retired_history").exists?
        raise ArgumentError, "Retained registers must still verify before activation" unless QuickbooksHistory::SourceFileVerificationService.new(batch: batch, actor: actor).call.all_verified
        raise ArgumentError, "Retained registers are incomplete" unless batch.reload.source_files_complete_and_verified?
        checks = batch.historical_paychecks.includes(:employee).to_a
        raise ArgumentError, "History adjustments require a separate reviewed amendment" if HistoricalPayroll::Ledger.new(batch: batch).adjustments.exists?
        validate_identities!(checks)
        summary = {
          "through_pay_date" => checks.map(&:pay_date).max.iso8601,
          "through_period_end" => checks.map(&:period_end).max.iso8601,
          "employee_count" => checks.map(&:employee_id).uniq.size,
          "balance_count" => checks.map(&:employee_id).uniq.size,
          "adjustment_digest" => HistoricalPayroll::Ledger.new(batch: batch).adjustment_digest,
          "prior_provider_onboarding_id" => onboarding.id
        }
        batch.update!(status: "locked", locked_at: Time.current, locked_by: actor)
        bridge = batch.historical_ytd_bridges.create!(company: company, prior_provider_history_onboarding: onboarding,
          created_by: actor, plan_digest: onboarding.preview_digest, preview_summary: summary,
          reconciliation_summary: batch.reconciliation_summary, status: "previewed")
        checks.group_by(&:employee_id).each do |employee_id, rows|
          amounts = Amounts.totals(rows.map { |row| row.source_metadata.fetch("verified_amounts") })
          attributes = amounts.slice(*HistoricalEmployeeYtdBalance.column_names).except("company_id", "employee_id")
          source_breakdown = Amounts::BREAKDOWNS.to_h do |field|
            values = Hash.new(0.to_d)
            rows.each { |row| row.public_send(field).each { |component| values[component.fetch("label")] += component.fetch("amount").to_d } }
            [ field, values.transform_values { |value| value.to_s("F") } ]
          end
          # Preserve explicit classification even when the provider uses a label
          # different from QuickBooks' deduction-label convention.
          source_breakdown["prior_provider_verified"] = true
          bridge.historical_employee_ytd_balances.create!(attributes.merge(
            company: company, employee_id: employee_id, tax_year: onboarding.tax_year,
            through_pay_date: rows.map(&:pay_date).max, through_period_end: rows.map(&:period_end).max,
            employee_taxes: rows.sum(0.to_d, &:employee_taxes), source_breakdown: source_breakdown
          ))
        end
        bridge.update!(status: "applied", applied_at: Time.current, applied_by: actor, apply_acknowledgement: acknowledgement)
        before = company.payroll_filing_responsibilities.for_year(onboarding.tax_year).map(&:attributes)
        record_filing_responsibilities!(summary.fetch("through_pay_date"))
        after = company.payroll_filing_responsibilities.for_year(onboarding.tax_year).map(&:attributes)
        onboarding.update!(status: "active", activated_at: Time.current, activated_by: actor, filing_before: before, filing_after: after)
        audit!("activate", bridge_id: bridge.id, through_pay_date: summary.fetch("through_pay_date"))
        onboarding
      end
    end

    private

    attr_reader :onboarding, :actor, :acknowledgement
    def company = onboarding.company
    def batch = onboarding.historical_import_batch

    def validate_identities!(checks)
      payload = onboarding.evidence.fetch("payload")
      checks.each do |check|
        identity = payload.fetch("identities").fetch(check.employee_id.to_s)
        unless check.employee&.company_id == company.id && check.employee.full_name.squish.downcase == identity.fetch("source_name").squish.downcase && check.employee.ssn_last_four == identity.fetch("ssn_last4")
          raise ArgumentError, "Employee identity changed after conversion; reverse and reconcile the roster again"
        end
      end
    end

    def record_filing_responsibilities!(cutoff)
      (1..4).each do |quarter|
        quarter_end = Date.new(onboarding.tax_year, quarter * 3, -1)
        party = quarter_end < onboarding.takeover_on ? "external_provider" : "cornerstone"
        PayrollFilingResponsibilityRecorder.new(company: company, actor: actor, tax_year: onboarding.tax_year, quarter: quarter,
          filing_types: PayrollFilingResponsibility::QUARTERLY_FILING_TYPES, responsible_party: party,
          imported_payroll_inclusion: "included", source_cutoff_date: cutoff,
          notes: "#{batch.source_label}: paid history through #{cutoff}; takeover #{onboarding.takeover_on}. Reconcile prior-provider returns and deposits; history creates no payments.").call
      end
      PayrollFilingResponsibilityRecorder.new(company: company, actor: actor, tax_year: onboarding.tax_year,
        filing_types: [ "w2_gu" ], responsible_party: "cornerstone", imported_payroll_inclusion: "included",
        source_cutoff_date: cutoff, notes: "Cornerstone owns full-year W-2GU/W-3SS, including the verified prior-provider history exactly once.").call
    end

    def audit!(action, metadata)
      AuditLog.record!(user: actor, company_id: company.id, organization_id: company.organization_id,
        action: "prior_provider_history##{action}", record_type: "prior_provider_history_onboardings", record_id: onboarding.id,
        subject_name: batch.source_label, metadata: metadata)
    end
  end
end
