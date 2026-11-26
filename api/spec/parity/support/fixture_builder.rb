# frozen_string_literal: true

module Parity
  # Builds a self-contained, entirely fictional company and roster using the
  # suite's own factories and real calculators/services (never the demo seed).
  #
  # Roster fixtures:
  #   1. hourly_overtime               — hourly + OT + PTO + Holiday + suffix ("JR") + paper check
  #   2. salaried_401k                 — salaried + 4% pre-tax 401(k) + 3% ER match + DD + check_date offset
  #   3. additional_withholding_med    — W-4 4(c) additional withholding + >$200k Additional Medicare + suffix ("III")
  #   4. prior_provider_ytd            — QuickBooks locked paycheck + non-taxable reimb + QB adjustment + applied YTD bridge + native check
  #   5. voided_check                  — multi-period: Period 1 clean + Period 2 paper check voided (wages still owed, not reversed)
  #   6. reversed_paycheck             — multi-period: Period 1 stands + Period 2 reversed via ReversePaycheckService
  #   7. corrective_paycheck           — multi-period: Period 1 original + IssueCorrectivePaycheckService delta + Period 2
  #   8. terminated_employee           — multi-period: Period 1 + Period 2, then terminated with former-employee portal link
  #   9. contractor_transition         — multi-period: W-2 hourly in Period 1 & Period 2, then employee record changed to contractor (L6)
  #  10. roth_401k                     — multi-period: salaried + 5% Roth 401(k) + 2% ER Roth match (W-2 Box 12 AA)
  #  11. native_non_taxable            — multi-period: hourly + native non-taxable addition ("Uniform Reimbursement")
  #  12. true_contractor               — multi-period: true 1099 contractor from day 1 (zero taxes, excluded from W-2GU)
  #  13. same_period_bonus             — two checks in the same period (regular + same-date bonus run) + Period 2
  class FixtureBuilder
    TAX_YEAR = 2026
    PERIOD1_START = Date.new(2026, 1, 19)
    PERIOD1_END   = Date.new(2026, 2, 1)
    PERIOD1_PAY   = Date.new(2026, 2, 6)

    PERIOD2_START = Date.new(2026, 2, 2)
    PERIOD2_END   = Date.new(2026, 2, 15)
    PERIOD2_PAY   = Date.new(2026, 2, 20)
    PERIOD2_ALT_CHECK_DATE = Date.new(2026, 2, 21)

    FUTURE_PERIOD_START = Date.new(2026, 3, 2)
    FUTURE_PERIOD_END   = Date.new(2026, 3, 15)
    FUTURE_PERIOD_PAY   = Date.new(2026, 3, 20)

    QB_PERIOD_START = Date.new(2026, 1, 1)
    QB_PERIOD_END   = Date.new(2026, 1, 14)
    QB_PERIOD_PAY   = Date.new(2026, 1, 16)

    CORRECTIVE_PAY_DATE = Date.new(2026, 2, 13)
    POSTING_NOW = Time.find_zone!(PayStubGenerator::GUAM_TIME_ZONE).local(2026, 2, 25, 10, 0, 0)
    AIRE_SHARED_SECRET = "parity-aire-shared-secret"

    ALL_SCENARIOS = %i[
      hourly_overtime
      salaried_401k
      additional_withholding_med
      prior_provider_ytd
      voided_check
      reversed_paycheck
      corrective_paycheck
      terminated_employee
      contractor_transition
      roth_401k
      native_non_taxable
      true_contractor
      same_period_bonus
    ].freeze

    attr_reader :organization, :company, :department, :staff_user, :client_user,
      :period1, :period1_bonus, :period2, :corrective_period, :future_period,
      :employees, :links, :users, :items, :documents, :qb_records, :w2_documents,
      :aire_source, :aire_worker_uuids

    def initialize(stored_pdfs:, include_w2: false, scenarios: :all, include_future_period: false, include_aire: false)
      @stored_pdfs = stored_pdfs
      @include_w2 = include_w2
      @selected_scenarios = scenarios == :all ? ALL_SCENARIOS : Array(scenarios).map(&:to_sym)
      @include_future_period = include_future_period
      @include_aire = include_aire
      @employees = {}
      @links = {}
      @users = {}
      @items = {}
      @documents = {}
      @qb_records = {}
      @w2_documents = {}
      @aire_worker_uuids = {}
    end

    def build!
      setup_tax_year_2026!
      setup_company_and_actors!
      setup_employees!
      setup_aire_source! if @include_aire
      setup_prior_provider_history! if selected?(:prior_provider_ytd)
      setup_period1! if needs_period1?
      setup_period1_bonus! if selected?(:same_period_bonus)
      setup_corrective_paycheck! if selected?(:corrective_paycheck)
      setup_period2! if needs_period2?
      setup_voided_check! if selected?(:voided_check)
      setup_reversed_paycheck! if selected?(:reversed_paycheck)
      setup_terminated_employee! if selected?(:terminated_employee)
      setup_contractor_transition! if selected?(:contractor_transition)
      setup_future_committed_period! if @include_future_period && selected?(:hourly_overtime)
      post_w2_copies! if @include_w2
      self
    end

    # Lazily posts a single item's frozen employee pay stub on demand so specs
    # only pay PDF generation cost for the items they actually inspect.
    def ensure_stub_posted!(item_key, now: POSTING_NOW)
      return @documents[item_key] if @documents.key?(item_key) && now == POSTING_NOW

      item = items.fetch(item_key)
      # Delta corrective stubs require their original item's stub to be posted first.
      if item_key == :corrective_delta
        ensure_stub_posted!(:corrective_original_p1)
      end

      doc = TenantScope.as_system(reason: "Parity fixture posts pay stub for #{item_key}") do
        EmployeeDocuments::PostPayStub.new(item, now: now).call
      end
      @documents[item_key] = doc if now == POSTING_NOW || doc.present?
      doc
    end

    private

    def selected?(key)
      @selected_scenarios.include?(key)
    end

    def needs_period1?
      %i[
        hourly_overtime salaried_401k additional_withholding_med
        voided_check reversed_paycheck corrective_paycheck terminated_employee
        contractor_transition roth_401k native_non_taxable true_contractor
        same_period_bonus
      ].any? { |k| selected?(k) }
    end

    def needs_period2?
      %i[
        hourly_overtime salaried_401k additional_withholding_med prior_provider_ytd
        voided_check reversed_paycheck corrective_paycheck terminated_employee
        contractor_transition roth_401k native_non_taxable true_contractor
        same_period_bonus
      ].any? { |k| selected?(k) }
    end

    def setup_tax_year_2026!
      unless AnnualTaxConfig.for_year(TAX_YEAR)
        config = AnnualTaxConfig.create!(
          tax_year: TAX_YEAR,
          ss_wage_base: BigDecimal("184500.00"),
          ss_rate: BigDecimal("0.062"),
          medicare_rate: BigDecimal("0.0145"),
          additional_medicare_rate: BigDecimal("0.009"),
          additional_medicare_threshold: BigDecimal("200000.00"),
          is_active: true,
          verification_status: "verified",
          verified_by: "parity-fixture",
          verified_at: Time.current,
          source_references: "Parity synthetic 2026 tax config"
        )
        single = FilingStatusConfig.create!(
          annual_tax_config: config,
          filing_status: "single",
          standard_deduction: BigDecimal("15000.00")
        )
        [
          [ 1, BigDecimal("0"), BigDecimal("11925"), BigDecimal("0.10") ],
          [ 2, BigDecimal("11925"), BigDecimal("48475"), BigDecimal("0.12") ],
          [ 3, BigDecimal("48475"), BigDecimal("103350"), BigDecimal("0.22") ],
          [ 4, BigDecimal("103350"), BigDecimal("197300"), BigDecimal("0.24") ],
          [ 5, BigDecimal("197300"), BigDecimal("250525"), BigDecimal("0.32") ],
          [ 6, BigDecimal("250525"), BigDecimal("626350"), BigDecimal("0.35") ],
          [ 7, BigDecimal("626350"), nil, BigDecimal("0.37") ]
        ].each do |order, min_inc, max_inc, rate|
          TaxBracket.create!(
            filing_status_config: single,
            bracket_order: order,
            min_income: min_inc,
            max_income: max_inc,
            rate: rate
          )
        end
        config.update_columns(verification_status: "verified", verified_at: Time.current, verified_by: "parity-fixture")
      end

      unless InformationReturnThreshold.exists?(tax_year: TAX_YEAR, form_type: "1099_nec")
        FactoryBot.create(:information_return_threshold, tax_year: TAX_YEAR, threshold_amount: BigDecimal("2000.00"))
      end
    end

    def setup_company_and_actors!
      @organization = FactoryBot.create(:organization, name: "Cornerstone Parity Practice")
      @company = FactoryBot.create(
        :company,
        organization: organization,
        name: "Harbor Parity Foods LLC",
        ein: "98-7000100",
        address_line1: "100 Parity Loop",
        city: "Tamuning",
        state: "GU",
        zip: "96913",
        phone: "671-555-0100",
        email: "payroll@parity.example.test",
        pay_frequency: "biweekly",
        auto_create_fit_check: false,
        # 6-digit starting check number exercises last-4 normalization across views,
        # and the memo template prints the check number onto the check face PDF.
        next_check_number: 105_001,
        check_memo_template: 'Payroll {period_start} - {period_end} · Check #{check_number}'
      )
      @department = FactoryBot.create(:department, company: company, name: "Operations")

      @staff_user = FactoryBot.create(
        :user,
        company: company,
        organization: organization,
        role: :admin,
        name: "Sam Staff",
        email: "staff@parity.example.test",
        clerk_id: "user_parity_staff"
      )
      @client_user = FactoryBot.create(
        :user,
        company: company,
        organization: organization,
        role: :client,
        name: "Claire Manager",
        email: "client@parity.example.test",
        clerk_id: "user_parity_client"
      )
      CompanyAssignment.create!(user: client_user, company: company)

      company.client_operating_profiles.create!(
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "payroll_service",
        hours_source: "manual",
        employee_portal_enabled: true,
        options: {
          "employee_portal" => {
            "features" => {
              "stubs" => true,
              "tax_forms" => true,
              "profile_requests" => true
            }
          }
        }
      )
      TenantScope.as_system(reason: "Parity fixture activates employee app") do
        EmployeeAppSwitch::KEYS.each do |part|
          EmployeeAppActivation.activate!(company: company, part: part, actor: staff_user, checks: [])
        end
      end
      TenantSubdomainRegistry.invalidate!
    end

    def setup_employees!
      specs = {
        hourly_overtime: {
          first_name: "Mateo", middle_name: "A", last_name: "Cruz", name_suffix: "JR",
          email: "mateo.cruz@parity.example.test", phone: "671-555-0101",
          address_line1: "101 Coral Way", address_line2: "Unit 2A", city: "Tamuning", state: "GU", zip: "96913",
          ssn_encrypted: "900-70-0101", employment_type: "hourly", pay_rate: BigDecimal("20.00"),
          payment_delivery_method: "paper_check"
        },
        salaried_401k: {
          first_name: "Nora", middle_name: "M", last_name: "Delgado",
          email: "nora.delgado@parity.example.test", phone: "671-555-0102",
          address_line1: "202 Lagoon Rd", city: "Dededo", state: "GU", zip: "96929",
          ssn_encrypted: "900-70-0102", employment_type: "salary", salary_type: "annual", pay_rate: BigDecimal("78000.00"),
          retirement_rate: BigDecimal("0.04"), employer_retirement_match_rate: BigDecimal("0.03"),
          payment_delivery_method: "direct_deposit"
        },
        additional_withholding_med: {
          first_name: "Carlos", last_name: "Reyes", name_suffix: "III",
          email: "carlos.reyes@parity.example.test", phone: "671-555-0103",
          address_line1: "303 Cliffline Dr", city: "Tamuning", state: "GU", zip: "96913",
          ssn_encrypted: "900-70-0103", employment_type: "salary", salary_type: "annual", pay_rate: BigDecimal("130000.00"),
          additional_withholding: BigDecimal("75.00"),
          payment_delivery_method: "paper_check"
        },
        prior_provider_ytd: {
          first_name: "Lina", last_name: "Perez",
          email: "lina.perez@parity.example.test", phone: "671-555-0104",
          address_line1: "404 Tradewind Ave", city: "Barrigada", state: "GU", zip: "96913",
          ssn_encrypted: "900-70-0104", employment_type: "hourly", pay_rate: BigDecimal("22.00"),
          payment_delivery_method: "paper_check"
        },
        voided_check: {
          first_name: "Tomas", last_name: "Mesa",
          email: "tomas.mesa@parity.example.test", phone: "671-555-0105",
          address_line1: "505 Palm Ct", city: "Yigo", state: "GU", zip: "96929",
          ssn_encrypted: "900-70-0105", employment_type: "hourly", pay_rate: BigDecimal("18.00"),
          payment_delivery_method: "paper_check"
        },
        reversed_paycheck: {
          first_name: "Elena", last_name: "Santos",
          email: "elena.santos@parity.example.test", phone: "671-555-0109",
          address_line1: "909 Bayshore Dr", city: "Tamuning", state: "GU", zip: "96913",
          ssn_encrypted: "900-70-0109", employment_type: "hourly", pay_rate: BigDecimal("24.00"),
          payment_delivery_method: "paper_check"
        },
        corrective_paycheck: {
          first_name: "Sofia", last_name: "Flores",
          email: "sofia.flores@parity.example.test", phone: "671-555-0106",
          address_line1: "606 Breeze Ln", city: "Mangilao", state: "GU", zip: "96913",
          ssn_encrypted: "900-70-0106", employment_type: "hourly", pay_rate: BigDecimal("25.00"),
          payment_delivery_method: "paper_check"
        },
        terminated_employee: {
          first_name: "David", last_name: "Leon",
          email: "david.leon@parity.example.test", phone: "671-555-0107",
          address_line1: "707 Harbor View", city: "Hagatna", state: "GU", zip: "96910",
          ssn_encrypted: "900-70-0107", employment_type: "hourly", pay_rate: BigDecimal("19.00"),
          payment_delivery_method: "paper_check"
        },
        contractor_transition: {
          first_name: "Ramon", last_name: "Torres",
          email: "ramon.torres@parity.example.test", phone: "671-555-0108",
          address_line1: "808 Reef St", city: "Agat", state: "GU", zip: "96915",
          ssn_encrypted: "900-70-0108", employment_type: "hourly", pay_rate: BigDecimal("30.00"),
          payment_delivery_method: "paper_check"
        },
        roth_401k: {
          first_name: "Maya", last_name: "Chen",
          email: "maya.chen@parity.example.test", phone: "671-555-0110",
          address_line1: "110 Flame Tree Ln", city: "Tamuning", state: "GU", zip: "96913",
          ssn_encrypted: "900-70-0110", employment_type: "salary", salary_type: "annual", pay_rate: BigDecimal("65000.00"),
          roth_retirement_rate: BigDecimal("0.05"), employer_roth_match_rate: BigDecimal("0.02"),
          payment_delivery_method: "paper_check"
        },
        native_non_taxable: {
          first_name: "Owen", last_name: "Bautista",
          email: "owen.bautista@parity.example.test", phone: "671-555-0111",
          address_line1: "111 Plumeria Way", city: "Dededo", state: "GU", zip: "96929",
          ssn_encrypted: "900-70-0111", employment_type: "hourly", pay_rate: BigDecimal("21.00"),
          payment_delivery_method: "paper_check"
        },
        true_contractor: {
          first_name: "Victor", last_name: "Sablan",
          email: "victor.sablan@parity.example.test", phone: "671-555-0112",
          address_line1: "112 Marine Corps Dr", city: "Hagatna", state: "GU", zip: "96910",
          ssn_encrypted: "900-70-0112", employment_type: "contractor", contractor_type: "individual",
          contractor_pay_type: "flat_fee", pay_rate: BigDecimal("1500.00"),
          payment_delivery_method: "paper_check"
        },
        same_period_bonus: {
          first_name: "Grace", last_name: "Tenorio",
          email: "grace.tenorio@parity.example.test", phone: "671-555-0113",
          address_line1: "113 Sunset Blvd", city: "Tamuning", state: "GU", zip: "96913",
          ssn_encrypted: "900-70-0113", employment_type: "salary", salary_type: "annual", pay_rate: BigDecimal("52000.00"),
          payment_delivery_method: "paper_check"
        }
      }

      specs.slice(*@selected_scenarios).each do |key, attrs|
        employee = FactoryBot.create(
          :employee,
          company: company,
          department: department,
          hire_date: Date.new(2025, 1, 1),
          date_of_birth: Date.new(1990, 5, 15),
          email_verified_at: Time.current,
          phone_confirmed_by_employee_at: Time.current,
          **attrs
        )
        portal_user = FactoryBot.create(
          :user,
          company: company,
          organization: organization,
          role: :portal_employee,
          name: employee.full_name,
          email: employee.email,
          clerk_id: "user_parity_#{key}"
        )
        link = EmployeeAccountLink.create!(
          user: portal_user,
          company: company,
          employee: employee,
          status: "active",
          activated_at: Time.current
        )
        @employees[key] = employee
        @users[key] = portal_user
        @links[key] = link

        if attrs[:additional_withholding].to_d.positive?
          EmployeeW4Election.create!(
            company: company,
            employee: employee,
            created_by: staff_user,
            source: "employee_creation",
            effective_on: Date.new(2025, 1, 1),
            filing_status: employee.filing_status,
            allowances: employee.allowances,
            additional_withholding: attrs[:additional_withholding],
            w4_form_version: 2020,
            reason: "Initial W-4 Step 4(c) election"
          )
        end

        if attrs[:roth_retirement_rate].to_d.positive?
          EmployeeRetirementElection.create!(
            company: company,
            employee: employee,
            created_by: staff_user,
            source: "employee_creation",
            effective_on: Date.new(2025, 1, 1),
            plan_name: "Harbor Parity 401(k)",
            plan_type: "standard_401k",
            limitation_year_type: "calendar",
            roth_available: true,
            employer_roth_available: false,
            plan_source_reference: "Parity Plan Doc 2026-01",
            eligible: true,
            participating: true,
            traditional_contribution_type: "percentage",
            traditional_rate: BigDecimal("0"),
            roth_contribution_type: "percentage",
            roth_rate: attrs[:roth_retirement_rate],
            eligible_compensation: "gross_wages",
            employer_match_mode: "compensation_percentage",
            employer_match_rate: attrs[:employer_roth_match_rate] || BigDecimal("0"),
            employer_match_destination: "traditional",
            reason: "Initial Roth 401(k) election"
          )
        end
      end
    end

    def setup_aire_source!
      @aire_source = FactoryBot.create(
        :time_tracking_source,
        company: company,
        source_type: "aire_services",
        shared_secret: AIRE_SHARED_SECRET
      )
      employees.each do |key, employee|
        uuid = SecureRandom.uuid
        TimeTrackingEmployeeMapping.create!(
          company: company,
          time_tracking_source: aire_source,
          employee: employee,
          source_user_id: "aire-parity-#{key}",
          source_user_uuid: uuid
        )
        @aire_worker_uuids[key] = uuid
      end
    end

    # Locked QuickBooks paycheck with non-taxable reimbursement, a ledger adjustment,
    # and an applied HistoricalYtdBridge through Jan 16, 2026.
    def setup_prior_provider_history!
      employee = employees[:prior_provider_ytd]
      batch = HistoricalImportBatch.create!(
        company: company,
        source_system: "quickbooks_online",
        source_label: "QuickBooks Parity Seed",
        bundle_digest: "parity-qb-batch-#{company.id}",
        importer_version: "quickbooks-online-payroll-v5",
        status: "locked",
        locked_at: Time.zone.parse("2026-01-17 09:00"),
        locked_by: staff_user
      )
      hist_period = HistoricalPayPeriod.create!(
        historical_import_batch: batch,
        company: company,
        external_key: "parity-qb-p1",
        source_label: "QB Pay 01/01/2026 - 01/14/2026",
        period_type: "regular",
        start_date: QB_PERIOD_START,
        end_date: QB_PERIOD_END,
        pay_date: QB_PERIOD_PAY,
        paycheck_count: 1,
        totals: { "gross_pay" => "1910.00", "net_pay" => "1613.79" }
      )
      hist_worker = HistoricalWorker.create!(
        historical_import_batch: batch,
        company: company,
        employee: employee,
        external_key: "parity-qb-lina",
        source_name: employee.full_name,
        normalized_name: employee.full_name.downcase,
        source_status: "active",
        mapping_status: "exact_match"
      )
      # QuickBooks gross_pay (1910.00) includes 150.00 non-taxable Mileage Reimb.
      # Taxable wages = 1760.00 (80h * $22).
      hist_paycheck = HistoricalPaycheck.create!(
        historical_import_batch: batch,
        historical_pay_period: hist_period,
        historical_worker: hist_worker,
        company: company,
        employee: employee,
        external_key: "parity-qb-check-1",
        source_employee_name: employee.full_name,
        source_row_number: 1,
        source_status: "Paid",
        reconciliation_status: "matched",
        period_start: QB_PERIOD_START,
        period_end: QB_PERIOD_END,
        pay_date: QB_PERIOD_PAY,
        check_number: "9001",
        payment_method: "Paper check",
        hours_total: BigDecimal("80.00"),
        hours_breakdown: [ { "label" => "Regular Pay", "amount" => "80.00" } ],
        gross_pay: BigDecimal("1910.00"),
        adjusted_gross: BigDecimal("1760.00"),
        earnings_breakdown: [
          { "label" => "Regular Pay", "amount" => "1760.00" },
          { "label" => "Mileage Reimb", "amount" => "150.00" }
        ],
        employee_taxes: BigDecimal("296.21"),
        federal_income_tax: BigDecimal("161.57"),
        social_security_tax: BigDecimal("109.12"),
        medicare_tax: BigDecimal("25.52"),
        pretax_deductions: BigDecimal("0.00"),
        after_tax_deductions: BigDecimal("0.00"),
        net_pay: BigDecimal("1613.79"),
        employer_taxes: BigDecimal("134.64"),
        employer_tax_breakdown: [
          { "label" => "Employer Social Security", "amount" => "109.12" },
          { "label" => "Employer Medicare", "amount" => "25.52" }
        ],
        employer_contributions: BigDecimal("0.00"),
        total_payroll_cost: BigDecimal("2044.64")
      )
      # Record a locked QuickBooks ledger adjustment (+$50 gross / +$40 net) to test L15.
      hist_adjustment = HistoricalPaycheckAdjustment.create!(
        company: company,
        historical_paycheck: hist_paycheck,
        created_by: staff_user,
        kind: "correction",
        effective_pay_date: QB_PERIOD_PAY,
        filing_year: TAX_YEAR,
        filing_quarter: 1,
        reason: "Parity fixture QuickBooks wage adjustment",
        idempotency_key: "parity-qb-adj-1",
        external_reference: "QB-ADJ-1",
        hours_total: BigDecimal("0.00"),
        gross_pay: BigDecimal("50.00"),
        adjusted_gross: BigDecimal("50.00"),
        pretax_deductions: BigDecimal("0.00"),
        employee_taxes: BigDecimal("10.00"),
        federal_income_tax: BigDecimal("6.17"),
        social_security_tax: BigDecimal("3.10"),
        medicare_tax: BigDecimal("0.73"),
        after_tax_deductions: BigDecimal("0.00"),
        net_pay: BigDecimal("40.00"),
        employer_taxes: BigDecimal("3.83"),
        employer_contributions: BigDecimal("0.00"),
        total_payroll_cost: BigDecimal("53.83"),
        employee_tax_breakdown: [
          { "label" => "Federal Income Tax", "amount" => "6.17" },
          { "label" => "Social Security", "amount" => "3.10" },
          { "label" => "Medicare", "amount" => "0.73" }
        ],
        employer_tax_breakdown: [
          { "label" => "Employer Social Security", "amount" => "3.10" },
          { "label" => "Employer Medicare", "amount" => "0.73" }
        ]
      )
      bootstrap = FactoryBot.create(
        :historical_client_bootstrap,
        company: company,
        historical_import_batch: batch,
        status: "applied"
      )
      bridge = HistoricalYtdBridge.create!(
        company: company,
        historical_import_batch: batch,
        historical_client_bootstrap: bootstrap,
        status: "applied",
        plan_digest: SecureRandom.hex(16),
        applied_at: Time.zone.parse("2026-01-17 10:00"),
        applied_by: staff_user,
        apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT,
        preview_summary: {
          "through_period_end" => QB_PERIOD_END.iso8601,
          "through_pay_date" => QB_PERIOD_PAY.iso8601,
          "adjustment_digest" => HistoricalPayroll::Ledger.new(batch: batch).adjustment_digest
        }
      )
      # Bridge balance incorporates QB check + adjustment:
      # gross_pay = 1960.00 (includes 150.00 non_taxable_pay -> taxable 1810.00)
      # FIT = 167.74, SS = 112.22, Medicare = 26.25, Net = 1653.79
      ytd_balance = HistoricalEmployeeYtdBalance.create!(
        historical_ytd_bridge: bridge,
        company: company,
        employee: employee,
        tax_year: TAX_YEAR,
        through_period_end: QB_PERIOD_END,
        through_pay_date: QB_PERIOD_PAY,
        gross_pay: BigDecimal("1960.00"),
        non_taxable_pay: BigDecimal("150.00"),
        fit_taxable_wages: BigDecimal("1810.00"),
        social_security_taxable_wages: BigDecimal("1810.00"),
        social_security_taxable_tips: BigDecimal("0.00"),
        medicare_taxable_wages: BigDecimal("1810.00"),
        federal_income_tax: BigDecimal("167.74"),
        social_security_tax: BigDecimal("112.22"),
        medicare_tax: BigDecimal("26.25"),
        net_pay: BigDecimal("1653.79"),
        source_breakdown: {
          "earnings_breakdown" => {
            "Regular Pay" => "1810.00",
            "Mileage Reimb" => "150.00"
          }
        }
      )

      @qb_records = {
        batch: batch,
        period: hist_period,
        paycheck: hist_paycheck,
        adjustment: hist_adjustment,
        bridge: bridge,
        ytd_balance: ytd_balance
      }
    end

    def setup_period1!
      @period1 = FactoryBot.create(
        :pay_period,
        company: company,
        start_date: PERIOD1_START,
        end_date: PERIOD1_END,
        pay_date: PERIOD1_PAY,
        status: "approved"
      )

      if selected?(:hourly_overtime)
        build_and_calculate_item!(:hourly_overtime, period1, key: :hourly_overtime_p1,
          hours_worked: BigDecimal("80.00"), overtime_hours: BigDecimal("4.00"),
          holiday_hours: BigDecimal("8.00"), pto_hours: BigDecimal("0.00"))
      end
      if selected?(:salaried_401k)
        build_and_calculate_item!(:salaried_401k, period1, key: :salaried_401k_p1,
          payment_delivery_method: "direct_deposit")
      end
      # Push Carlos Reyes III close to $200k ($198,000 in Period 1 via a large bonus)
      # so Period 2 crosses $200,000 and incurs real 0.9% Additional Medicare.
      if selected?(:additional_withholding_med)
        build_and_calculate_item!(:additional_withholding_med, period1, key: :additional_withholding_med_p1,
          bonus: BigDecimal("193000.00"), additional_withholding: BigDecimal("75.00"))
      end
      if selected?(:voided_check)
        build_and_calculate_item!(:voided_check, period1, key: :voided_check_p1,
          hours_worked: BigDecimal("80.00"))
      end
      if selected?(:reversed_paycheck)
        build_and_calculate_item!(:reversed_paycheck, period1, key: :reversed_paycheck_p1,
          hours_worked: BigDecimal("80.00"))
      end
      if selected?(:corrective_paycheck)
        build_and_calculate_item!(:corrective_paycheck, period1, key: :corrective_original_p1,
          hours_worked: BigDecimal("60.00"))
      end
      if selected?(:terminated_employee)
        build_and_calculate_item!(:terminated_employee, period1, key: :terminated_p1,
          hours_worked: BigDecimal("80.00"))
      end
      if selected?(:contractor_transition)
        build_and_calculate_item!(:contractor_transition, period1, key: :contractor_transition_p1,
          hours_worked: BigDecimal("40.00"))
      end
      if selected?(:roth_401k)
        build_and_calculate_item!(:roth_401k, period1, key: :roth_401k_p1)
      end
      if selected?(:native_non_taxable)
        build_and_calculate_item!(:native_non_taxable, period1, key: :native_non_taxable_p1,
          hours_worked: BigDecimal("80.00"),
          payroll_adjustments: [
            { "label" => "Uniform Reimbursement", "amount" => "125.00", "treatment" => "non_taxable_addition" }
          ])
      end
      if selected?(:true_contractor)
        build_and_calculate_item!(:true_contractor, period1, key: :true_contractor_p1)
      end
      if selected?(:same_period_bonus)
        build_and_calculate_item!(:same_period_bonus, period1, key: :same_period_bonus_p1_reg)
      end

      commit_period!(period1)
    end

    # Second check in the SAME pay period dates and SAME pay date (off-cycle bonus run).
    def setup_period1_bonus!
      @period1_bonus = FactoryBot.create(
        :pay_period,
        company: company,
        start_date: PERIOD1_START,
        end_date: PERIOD1_END,
        pay_date: PERIOD1_PAY,
        run_purpose: "bonus",
        includes_base_salary: false,
        includes_recurring_items: false,
        status: "approved"
      )
      build_and_calculate_item!(:same_period_bonus, period1_bonus, key: :same_period_bonus_p1_bonus,
        bonus: BigDecimal("500.00"))
      commit_period!(period1_bonus, committed_at: PERIOD1_PAY.to_time - 1.day)
    end

    def setup_corrective_paycheck!
      employee = employees[:corrective_paycheck]
      preview = IssueCorrectivePaycheckService.preview(
        original_pay_period: period1,
        employee: employee,
        corrected_inputs: { hours_worked: BigDecimal("80.00") }
      )
      supplemental, corrective_item = IssueCorrectivePaycheckService.issue!(
        original_pay_period: period1,
        employee: employee,
        corrected_inputs: { hours_worked: BigDecimal("80.00") },
        expected_review_digest: preview.fetch(:meta).fetch(:review_digest),
        pay_date: CORRECTIVE_PAY_DATE,
        reason: "Missed 20 regular hours on initial timesheet",
        actor: staff_user
      )
      @corrective_period = supplemental.reload
      @corrective_period.update_columns(committed_at: CORRECTIVE_PAY_DATE.to_time - 1.day)
      @items[:corrective_delta] = corrective_item.reload
    end

    def setup_period2!
      @period2 = FactoryBot.create(
        :pay_period,
        company: company,
        start_date: PERIOD2_START,
        end_date: PERIOD2_END,
        pay_date: PERIOD2_PAY,
        status: "approved"
      )

      # Mateo Cruz Jr.: 80 regular + 10 OT + 8 PTO + 8 Holiday = 106 combined hours
      if selected?(:hourly_overtime)
        build_and_calculate_item!(:hourly_overtime, period2, key: :hourly_overtime_p2,
          hours_worked: BigDecimal("80.00"), overtime_hours: BigDecimal("10.00"),
          pto_hours: BigDecimal("8.00"), holiday_hours: BigDecimal("8.00"))
      end
      # Nora Delgado: salaried + 4% 401(k) + 3% ER match + check_date != pay_period.pay_date (L11)
      if selected?(:salaried_401k)
        build_and_calculate_item!(:salaried_401k, period2, key: :salaried_401k_p2,
          payment_delivery_method: "direct_deposit", check_date: PERIOD2_ALT_CHECK_DATE)
      end
      # Carlos Reyes III: crosses $200,000 YTD -> real Additional Medicare + W-4 4(c) $75
      if selected?(:additional_withholding_med)
        build_and_calculate_item!(:additional_withholding_med, period2, key: :additional_withholding_med_p2,
          additional_withholding: BigDecimal("75.00"))
      end
      # Lina Perez: native Cornerstone paycheck AFTER QuickBooks bridge cutoff
      if selected?(:prior_provider_ytd)
        build_and_calculate_item!(:prior_provider_ytd, period2, key: :prior_provider_ytd_p2,
          hours_worked: BigDecimal("80.00"), overtime_hours: BigDecimal("5.00"))
      end
      if selected?(:voided_check)
        build_and_calculate_item!(:voided_check, period2, key: :voided_check_p2,
          hours_worked: BigDecimal("72.00"))
      end
      if selected?(:reversed_paycheck)
        build_and_calculate_item!(:reversed_paycheck, period2, key: :reversed_paycheck_p2,
          hours_worked: BigDecimal("60.00"))
      end
      if selected?(:corrective_paycheck)
        build_and_calculate_item!(:corrective_paycheck, period2, key: :corrective_p2,
          hours_worked: BigDecimal("80.00"))
      end
      if selected?(:terminated_employee)
        build_and_calculate_item!(:terminated_employee, period2, key: :terminated_p2,
          hours_worked: BigDecimal("40.00"))
      end
      if selected?(:contractor_transition)
        build_and_calculate_item!(:contractor_transition, period2, key: :contractor_transition_p2,
          hours_worked: BigDecimal("50.00"))
      end
      if selected?(:roth_401k)
        build_and_calculate_item!(:roth_401k, period2, key: :roth_401k_p2)
      end
      if selected?(:native_non_taxable)
        build_and_calculate_item!(:native_non_taxable, period2, key: :native_non_taxable_p2,
          hours_worked: BigDecimal("80.00"),
          payroll_adjustments: [
            { "label" => "Uniform Reimbursement", "amount" => "125.00", "treatment" => "non_taxable_addition" }
          ])
      end
      if selected?(:true_contractor)
        build_and_calculate_item!(:true_contractor, period2, key: :true_contractor_p2)
      end
      if selected?(:same_period_bonus)
        build_and_calculate_item!(:same_period_bonus, period2, key: :same_period_bonus_p2)
      end

      commit_period!(period2)
    end

    def setup_voided_check!
      # Period 1 stands clean; Period 2 has its paper check voided after posting
      # (instrument void only: wages remain legally owed and counted in YTD).
      item = items[:voided_check_p2]
      TenantScope.as_system(reason: "Parity fixture posts stub before void") do
        @documents[:voided_check_p2] = EmployeeDocuments::PostPayStub.new(item, now: POSTING_NOW).call
      end
      item.void!(user: staff_user, reason: "Paper check jammed in printer")
    end

    def setup_reversed_paycheck!
      # Period 1 stands clean; Period 2 is posted, then financially reversed via
      # ReversePaycheckService (removed from pay and YTD).
      item = items[:reversed_paycheck_p2]
      TenantScope.as_system(reason: "Parity fixture posts stub before reversal") do
        @documents[:reversed_paycheck_p2] = EmployeeDocuments::PostPayStub.new(item, now: POSTING_NOW).call
      end
      TenantScope.with_company(company.id) do
        ReversePaycheckService.call(
          payroll_item: item,
          actor: staff_user,
          reason: "Duplicate period entry financially reversed in parity fixture"
        )
      end
      # Run the posting sweep after reversal so the frozen stub transitions to withdrawn.
      TenantScope.as_system(reason: "Parity fixture sweeps withdrawn stub after reversal") do
        EmployeeDocuments::PostPayStub.new(item.reload, now: POSTING_NOW + 1.hour).call
      end
    end

    def setup_terminated_employee!
      employee = employees[:terminated_employee]
      employee.update!(status: "terminated", termination_date: PERIOD2_PAY)
      links[:terminated_employee].update!(
        status: "former",
        former_access_until: Time.current + 180.days
      )
    end

    def setup_contractor_transition!
      # Simulate legacy worker whose employee record is now contractor while Period 1 & 2
      # committed payroll_items retain employment_type: "hourly" (L6).
      employees[:contractor_transition].update_columns(
        employment_type: "contractor",
        contractor_type: "individual",
        contractor_pay_type: "flat_fee"
      )
    end

    # Committed period whose pay_date is AFTER POSTING_NOW so client sees it immediately
    # while employee posting holds it until 6:00 AM Guam time on pay_date (L10).
    def setup_future_committed_period!
      @future_period = FactoryBot.create(
        :pay_period,
        company: company,
        start_date: FUTURE_PERIOD_START,
        end_date: FUTURE_PERIOD_END,
        pay_date: FUTURE_PERIOD_PAY,
        status: "approved"
      )
      build_and_calculate_item!(:hourly_overtime, future_period, key: :hourly_overtime_future,
        hours_worked: BigDecimal("80.00"))
      commit_period!(future_period, committed_at: POSTING_NOW)
    end

    def build_and_calculate_item!(employee_key, period, key:, **attrs)
      employee = employees.fetch(employee_key)
      item = period.payroll_items.build(
        company: company,
        employee: employee,
        employment_type: employee.employment_type,
        pay_rate: employee.pay_rate,
        payment_delivery_method: attrs.delete(:payment_delivery_method) || employee.payment_delivery_method,
        **attrs
      )
      PayrollCalculator.for(employee, item).calculate
      item.save!
      @items[key] = item
    end

    # Commits through the real PayPeriodLifecycleService#commit! pipeline so
    # YTD snapshots (including historical bridges), check numbers, check events,
    # and liability postings match production behavior exactly.
    def commit_period!(period, committed_at: nil)
      TenantScope.with_company(company.id) do
        PayPeriodLifecycleService.new(pay_period: period, actor: staff_user).commit!
      end
      period.update_columns(committed_at: committed_at || period.pay_date.to_time - 2.days)
      period.payroll_items.each(&:reload)
      @items.each_value { |item| item.reload if item.pay_period_id == period.id }
    end

    def post_w2_copies!
      TenantScope.with_company(company.id) do
        { "w2_gu" => "cornerstone", "form_1099" => "no_filing" }.each do |filing_type, party|
          next if PayrollFilingResponsibility.exists?(company: company, tax_year: TAX_YEAR, filing_type: filing_type, quarter: nil)

          FactoryBot.create(
            :payroll_filing_responsibility,
            :annual,
            company: company,
            tax_year: TAX_YEAR,
            filing_type: filing_type,
            responsible_party: party,
            imported_payroll_inclusion: "included",
            reviewed_by: staff_user
          )
        end

        snapshot = W2GuOfficialCopies.snapshot(company, TAX_YEAR)
        readiness = W2FilingReadiness.find_or_initialize_by(company: company, year: TAX_YEAR)
        readiness.update!(
          status: "filing_ready",
          preflight_fingerprint: snapshot.fetch(:fingerprint),
          ready_fingerprint: snapshot.fetch(:fingerprint),
          marked_ready_at: POSTING_NOW,
          marked_ready_by: staff_user,
          notes: "Parity fixture W-2GU ready"
        )

        result = EmployeeDocuments::PostW2GuCopies.new(
          company: company,
          year: TAX_YEAR,
          user: staff_user
        ).call
        raise "Expected W-2GU posting to succeed, got #{result.status}: #{result.problems.inspect}" unless result.status == :posted

        result.documents.each do |doc|
          key = employees.key(doc.employee)
          @w2_documents[key] = doc if key
        end
      end
    end
  end
end
