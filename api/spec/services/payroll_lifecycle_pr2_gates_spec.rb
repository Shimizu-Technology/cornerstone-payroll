# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Lifecycle PR 2 pay-run readiness, stale-input fingerprint & commit safety net" do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Harborview Bistro") }
  let(:admin_user) { create(:user, company: company, organization: organization, role: "admin") }
  let(:org_admin) { create(:user, company: company, organization: organization, role: "org_admin") }

  before do
    ensure_verified_test_tax_years(2026)
  end

  def add_w4!(employee, effective_on: Date.new(2026, 1, 1), signed_on: Date.new(2026, 1, 1), source: "client_direct", version: 2020, filing_status: "single", additional_withholding: 0)
    EmployeeW4Election.create!(
      EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
        company: employee.company,
        employee: employee,
        filing_status: filing_status,
        additional_withholding: additional_withholding,
        effective_on: effective_on,
        w4_signed_on: signed_on,
        w4_form_version: version,
        source: source,
        reason: "Test W-4 setup"
      )
    )
  end

  def create_ready_enforced_employee(first_name: "Jordan", last_name: "Sample", **overrides)
    employee = create(
      :employee,
      :hourly,
      company: company,
      first_name: first_name,
      last_name: last_name,
      date_of_birth: Date.new(1994, 5, 14),
      hire_date: Date.new(2026, 1, 1),
      pay_rate: 20.00,
      pay_frequency: "biweekly",
      payment_delivery_method: "paper_check",
      readiness_gate_enforced: true,
      **overrides
    )
    add_w4!(employee)
    employee
  end

  def create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Example", **overrides)
    create(
      :employee,
      :hourly,
      company: company,
      first_name: first_name,
      last_name: last_name,
      date_of_birth: Date.new(1995, 6, 20),
      hire_date: Date.new(2026, 1, 1),
      pay_rate: 18.00,
      pay_frequency: "biweekly",
      payment_delivery_method: nil,
      readiness_gate_enforced: true,
      **overrides
    )
  end

  def build_calculated_period(employee:, run_purpose: "regular", run_purpose_source: "operator_selected", hours: 40, **period_attrs)
    period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 14),
      pay_date: Date.new(2026, 11, 20),
      status: "draft",
      run_purpose: run_purpose,
      run_purpose_source: run_purpose_source,
      **period_attrs
    )
    item = period.payroll_items.create!(
      company: company,
      employee: employee,
      employment_type: employee.employment_type,
      pay_rate: employee.pay_rate,
      hours_worked: hours,
      payment_delivery_method: employee.payment_delivery_method.presence || "paper_check"
    )
    item.calculate!
    period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)
    [ period, item.reload ]
  end

  describe "approval_first independence regression" do
    it "neither writes/enforces paycheck_input_fingerprint nor alters payment_delivery_method at calculate/approve time" do
      expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(false)

      legacy_employee = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Casey",
        last_name: "Legacy",
        pay_rate: 22.00,
        payment_delivery_method: nil,
        readiness_gate_enforced: false
      )
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: legacy_employee,
        employment_type: "hourly",
        pay_rate: 22.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )
      item.calculate!
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      snapshot = item.reload.calculation_context_snapshot.to_h
      expect(snapshot).not_to have_key("paycheck_input_fingerprint")
      expect(snapshot).not_to have_key("item_payment_delivery_method")
      expect(snapshot).not_to have_key("employee_payment_default_at_calculation")

      # Leave payment_delivery_method nil to verify approve! does not alter it for approval_first companies
      item.update_column(:payment_delivery_method, nil)

      # Changing pay rate and payment default on an approval_first employee does not trigger paycheck_input_fingerprint staleness
      EmployeeCompensationChangeService.new(
        employee: legacy_employee,
        pay_rate: 26.00,
        effective_on: period.start_date,
        actor: admin_user,
        source: "operator",
        reason: "Rate adjustment"
      ).call!
      legacy_employee.update!(payment_delivery_method: "direct_deposit")

      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period)).to eq([])
      expect { PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve! }.not_to raise_error
      expect(period.reload.status).to eq("approved")
      expect(item.reload.payment_delivery_method).to be_nil

      # Recalculating an approval_first item with an existing method keeps it unchanged
      period.update!(status: "calculated")
      item.update!(payment_delivery_method: "paper_check")
      item.calculate!
      expect(item.reload.payment_delivery_method).to eq("paper_check")
      expect(item.calculation_context_snapshot.to_h).not_to have_key("paycheck_input_fingerprint")
    end
  end

  describe "readiness exclusion across all non-exempt run purposes & payroll paths" do
    %w[regular off_cycle_tips bonus commission].each do |purpose|
      it "blocks an Incomplete readiness_gate_enforced hire on #{purpose} runs at roster, approve!, and commit!" do
        incomplete = create_incomplete_enforced_employee
        period, item = build_calculated_period(
          employee: incomplete,
          run_purpose: purpose,
          includes_base_salary: purpose == "regular",
          includes_recurring_items: purpose == "regular"
        )

        expect(Employee.where(id: incomplete.id).eligible_for_payroll_run(period, explicitly_selected: true)).to be_empty

        if purpose == "regular"
          draft = create(
            :pay_period,
            company: company,
            start_date: Date.new(2026, 11, 15),
            end_date: Date.new(2026, 11, 28),
            pay_date: Date.new(2026, 12, 4),
            status: "draft"
          )
          expect(PayPeriodDefaultRoster.new(draft).employee_ids).not_to include(incomplete.id)
          excluded = PayrollReadinessPolicy.readiness_excluded_employees_for(draft)
          expect(excluded.map { |row| row[:employee_id] }).to include(incomplete.id)
          expect(excluded.first[:reason]).to include("W-4 missing")
        end

        expect {
          PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
        }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)

        # Even if status were forced to approved, commit! still fails closed
        period.update_column(:status, "approved")
        expect {
          PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!
        }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)
        expect(item.reload).to be_present
      end
    end

    it "skips Incomplete hires with the exact reason in PayrollImport::ImportService#apply! and guards restore_without_hours!" do
      incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Example")
      ready = create_ready_enforced_employee(first_name: "Jordan", last_name: "Sample")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )

      service = PayrollImport::ImportService.new(period, actor: admin_user)
      results = service.apply!(
        matched: [
          { employee_id: incomplete.id, regular_hours: 32, overtime_hours: 0, total_tips: 0 },
          { employee_id: ready.id, regular_hours: 40, overtime_hours: 0, total_tips: 0 }
        ]
      )

      expect(results[:success].map { |row| row[:employee_id] }).to eq([ ready.id ])
      expect(results[:skipped].size).to eq(1)
      expect(results[:skipped].first).to include(
        employee_id: incomplete.id,
        name: "Morgan Example",
        code: "employee_readiness_incomplete"
      )
      expect(results[:skipped].first[:reason]).to include("W-4 missing")
      expect(results[:skipped].first[:reason]).to include("Hours were not imported")
      expect(period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)

      expect {
        service.restore_without_hours!(
          employee: incomplete,
          row: { total_tips: 0, loan_deduction: 0 },
          tips_paid_out_from_tips: false
        )
      }.to raise_error(ArgumentError, /W-4 missing/)
    end

    it "allows an Incomplete hire when covered by an active EmployeeReadinessOverride and blocks if a new key is missing" do
      incomplete = create_incomplete_enforced_employee
      period, _item = build_calculated_period(employee: incomplete)

      override_record = AdminOverride.create!(
        company: company,
        actor: org_admin,
        action: "readiness_override",
        subject_type: "Employee",
        subject_id: incomplete.id,
        before_snapshot: {},
        after_snapshot: {},
        preflight_result: {},
        reason: "Urgent first payroll while waiting on paperwork"
      )
      readiness_override = EmployeeReadinessOverride.create!(
        company: company,
        employee: incomplete,
        pay_period: period,
        missing_items_snapshot: %w[tax_form payment_method],
        default_w4_acknowledged: true,
        reason: "Urgent first payroll while waiting on paperwork",
        granted_by: org_admin,
        granted_at: Time.current,
        admin_override: override_record
      )

      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: incomplete)).to be_nil

      # Adding a new missing item (e.g. blank DOB) that was not in missing_items_snapshot fails closed
      incomplete.update_column(:date_of_birth, nil)
      blocker = PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: incomplete.reload)
      expect(blocker).to be_present
      expect(blocker.missing_keys).to include("date_of_birth")

      # Restore DOB, then revoke override -> blocked again
      incomplete.update_column(:date_of_birth, Date.new(1995, 6, 20))
      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: incomplete.reload)).to be_nil
      readiness_override.update!(revoked_at: Time.current, revoked_by: org_admin, revoke_reason: "No longer needed")
      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: incomplete.reload)).to be_present
    end
  end

  describe "narrowed run-purpose exemptions (§6.4) & W2GuAggregator" do
    it "on final runs, exempts genuinely terminated Incomplete hires but blocks active and deactivated/inactive hires" do
      terminated = create_incomplete_enforced_employee(
        first_name: "Taylor",
        last_name: "Terminated",
        status: "terminated",
        termination_date: Date.new(2026, 11, 10)
      )
      active_hire = create_incomplete_enforced_employee(first_name: "Alex", last_name: "Active")
      deactivated_hire = create_incomplete_enforced_employee(
        first_name: "Drew",
        last_name: "Deactivated",
        status: "inactive"
      )
      EmployeeStatusEvent.create!(
        company: company,
        employee: deactivated_hire,
        event_type: "deactivated",
        previous_status: "active",
        resulting_status: "inactive",
        effective_date: Date.new(2026, 11, 10),
        reason_category: "leave_of_absence",
        source: "operator",
        actor: admin_user
      )

      final_period, _item = build_calculated_period(
        employee: terminated,
        run_purpose: "final",
        includes_base_salary: false,
        includes_recurring_items: false
      )

      # Terminated worker is exempt and commits cleanly
      expect(Employee.where(id: [ terminated.id, active_hire.id, deactivated_hire.id ])
        .eligible_for_payroll_run(final_period, explicitly_selected: true).pluck(:id)).to eq([ terminated.id ])

      PayPeriodLifecycleService.new(pay_period: final_period, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: final_period, actor: admin_user).commit!
      expect(final_period.reload.status).to eq("committed")

      # Active hire is blocked on final runs
      active_final, _ = build_calculated_period(
        employee: active_hire,
        run_purpose: "final",
        includes_base_salary: false,
        includes_recurring_items: false
      )
      expect {
        PayPeriodLifecycleService.new(pay_period: active_final, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)

      # Deactivated/inactive hire is also blocked on final runs (closes accountant deactivate -> final -> reactivate bypass)
      deactivated_final, _ = build_calculated_period(
        employee: deactivated_hire,
        run_purpose: "final",
        includes_base_salary: false,
        includes_recurring_items: false
      )
      expect {
        PayPeriodLifecycleService.new(pay_period: deactivated_final, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)

      # W2GuAggregator includes terminated workers with committed reportable pay
      w2_report = W2GuAggregator.new(company, 2026).generate
      expect(w2_report[:employees].map { |row| row[:employee_id] }).to include(terminated.id)
    end

    it "on adjustment runs, exempts late-hours origin adjustments and terminated workers with prior committed pay, but blocks ad-hoc active hires even with a prior overridden paycheck" do
      # 1. Active Incomplete hire who previously received an overridden committed paycheck
      active_hire = create_incomplete_enforced_employee(first_name: "Casey", last_name: "Overridden")
      prior_period, _ = build_calculated_period(
        employee: active_hire,
        start_date: Date.new(2026, 10, 1),
        end_date: Date.new(2026, 10, 14),
        pay_date: Date.new(2026, 10, 20)
      )
      admin_ov = AdminOverride.create!(
        company: company,
        actor: org_admin,
        action: "readiness_override",
        subject_type: "Employee",
        subject_id: active_hire.id,
        before_snapshot: {},
        after_snapshot: {},
        preflight_result: {},
        reason: "Approved first cycle while awaiting W-4"
      )
      EmployeeReadinessOverride.create!(
        company: company,
        employee: active_hire,
        pay_period: prior_period,
        missing_items_snapshot: %w[tax_form payment_method],
        default_w4_acknowledged: true,
        reason: "Approved first cycle while awaiting W-4",
        granted_by: org_admin,
        granted_at: Time.current,
        admin_override: admin_ov
      )
      PayPeriodLifecycleService.new(pay_period: prior_period, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: prior_period, actor: admin_user).commit!

      # W2GuAggregator includes the overridden worker
      w2_report = W2GuAggregator.new(company, 2026).generate
      expect(w2_report[:employees].map { |row| row[:employee_id] }).to include(active_hire.id)

      # Ad-hoc adjustment run for that active hire is STILL blocked without a new override
      adhoc_adj, _ = build_calculated_period(
        employee: active_hire,
        run_purpose: "adjustment",
        includes_base_salary: false,
        includes_recurring_items: false
      )
      expect {
        PayPeriodLifecycleService.new(pay_period: adhoc_adj, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)

      # 2. Terminated worker with prior committed pay IS exempt on adjustment runs
      active_hire.update!(status: "terminated", termination_date: Date.new(2026, 11, 5))
      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: adhoc_adj, employee: active_hire)).to be_nil

      # 3. Active Incomplete hire on a TimeTrackingLateHoursRun-linked adjustment with committed origin allocations IS exempt
      late_hire = create_incomplete_enforced_employee(first_name: "Riley", last_name: "LateHours")
      late_adj, late_item = build_calculated_period(
        employee: late_hire,
        run_purpose: "adjustment",
        includes_base_salary: false,
        includes_recurring_items: false,
        start_date: prior_period.start_date,
        end_date: prior_period.end_date,
        pay_date: Date.new(2026, 11, 20)
      )
      source = create(:time_tracking_source, company: company)
      import = TimeTrackingImport.create!(
        pay_period: late_adj,
        time_tracking_source: source,
        start_date: prior_period.start_date,
        end_date: prior_period.end_date,
        fetch_start_date: prior_period.start_date,
        fetch_end_date: prior_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("late-hours-test"),
        status: "applied",
        applied_at: Time.current,
        applied_by: admin_user,
        raw_payload: {},
        processed_payload: {}
      )
      TimeTrackingLateHoursRun.create!(
        company: company,
        time_tracking_source: source,
        origin_pay_period: prior_period,
        adjustment_pay_period: late_adj,
        created_by: admin_user,
        command_id: SecureRandom.uuid,
        state: "applied",
        applied_at: Time.current,
        request_payload: {},
        rate_snapshot: [],
        selection_snapshot: [ { "id" => "case-1", "payroll_employee_id" => late_hire.id } ]
      )
      TimeTrackingEntryAllocation.create!(
        company: company,
        pay_period: late_adj,
        payroll_item: late_item,
        employee: late_hire,
        time_tracking_import: import,
        time_tracking_source: source,
        source_time_entry_id: "entry-1",
        source_user_id: "u-1",
        source_kind: "carryover",
        line_key: "reg-1",
        original_work_date: prior_period.start_date + 2.days,
        regular_hours: 4,
        overtime_hours: 0,
        total_hours: 4,
        category_snapshot: {},
        earning_snapshot: {}
      )

      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: late_adj.reload, employee: late_hire, payroll_item: late_item)).to be_nil
      # An unrelated active Incomplete hire NOT in the late-hours run is still blocked on late_adj
      unrelated = create_incomplete_enforced_employee(first_name: "Unrelated", last_name: "Worker")
      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: late_adj, employee: unrelated)).to be_present
    end

    it "on correction runs, exempts only paychecks linked to a verified source paycheck, blocks unrelated Incomplete hires, blocks operator-created correction drafts, and stales unlinked eligible items on rate change" do
      # Commit a regular run with a ready enforced employee, then void & create a system correction run
      source_worker = create_ready_enforced_employee(first_name: "Jordan", last_name: "Source")
      origin_period, origin_item = build_calculated_period(
        employee: source_worker,
        start_date: Date.new(2026, 10, 1),
        end_date: Date.new(2026, 10, 14),
        pay_date: Date.new(2026, 10, 20)
      )
      PayPeriodLifecycleService.new(pay_period: origin_period, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: origin_period, actor: admin_user).commit!

      # 1. Single-employee corrective paycheck (IssueCorrectivePaycheckService) commits even if employee later becomes incomplete/terminated
      source_worker.update!(status: "terminated", termination_date: Date.new(2026, 10, 25))
      source_worker.update_column(:date_of_birth, nil)
      supplemental_period, _corrective_item = IssueCorrectivePaycheckService.new(
        original_pay_period: origin_period,
        employee: source_worker,
        corrected_inputs: { hours_worked: 44 },
        pay_date: Date.new(2026, 11, 20),
        reason: "Missed 4 regular hours on original check",
        actor: admin_user
      ).issue!
      expect(supplemental_period.status).to eq("committed")

      # 2. Operator-created ad-hoc correction draft is NOT exempt
      incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Unrelated")
      adhoc_correction, _ = build_calculated_period(
        employee: incomplete,
        run_purpose: "correction",
        run_purpose_source: "operator_selected",
        includes_base_salary: false,
        includes_recurring_items: false
      )
      expect {
        PayPeriodLifecycleService.new(pay_period: adhoc_correction, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)

      # 3. System-generated void+redo correction run:
      # Create a second committed period with an overridden Incomplete worker so we can void and redo it
      overridden_worker = create_incomplete_enforced_employee(first_name: "Sam", last_name: "Origin")
      period2, _ = build_calculated_period(
        employee: overridden_worker,
        start_date: Date.new(2026, 10, 15),
        end_date: Date.new(2026, 10, 28),
        pay_date: Date.new(2026, 11, 3)
      )
      ov = AdminOverride.create!(
        company: company,
        actor: org_admin,
        action: "readiness_override",
        subject_type: "Employee",
        subject_id: overridden_worker.id,
        before_snapshot: {},
        after_snapshot: {},
        preflight_result: {},
        reason: "First period readiness override for source run"
      )
      EmployeeReadinessOverride.create!(
        company: company,
        employee: overridden_worker,
        pay_period: period2,
        missing_items_snapshot: %w[tax_form payment_method],
        default_w4_acknowledged: true,
        reason: "First period readiness override for source run",
        granted_by: org_admin,
        granted_at: Time.current,
        admin_override: ov
      )
      PayPeriodLifecycleService.new(pay_period: period2, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: period2, actor: admin_user).commit!

      # Mark period2 voided and create system correction run
      period2.update_columns(correction_status: "voided", voided_at: Time.current, voided_by_id: org_admin.id, void_reason: "Void for redo")
      correction_run = PayPeriodCorrectionService.create_correction_run!(
        source_pay_period: period2,
        actor: org_admin,
        reason: "Re-issue corrected run"
      )
      copied_item = correction_run.payroll_items.find_by!(employee_id: overridden_worker.id)
      expect(copied_item.financial_correction_origin_item_id).to be_present
      copied_item.calculate!
      correction_run.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      # (a) Unrelated Incomplete employee added to the correction draft is blocked at approve! and commit!
      unrelated_item = correction_run.payroll_items.create!(
        company: company,
        employee: incomplete,
        employment_type: "hourly",
        pay_rate: 18.00,
        hours_worked: 10,
        payment_delivery_method: "paper_check"
      )
      unrelated_item.calculate!
      expect {
        PayPeriodLifecycleService.new(pay_period: correction_run, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Morgan Unrelated.*W-4 missing/)
      correction_run.update_column(:status, "approved")
      expect {
        PayPeriodLifecycleService.new(pay_period: correction_run, actor: admin_user).commit!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Morgan Unrelated.*W-4 missing/)

      unrelated_item.destroy!
      correction_run.update_column(:status, "calculated")

      # (b) An unlinked, readiness-eligible employee on the correction draft goes stale when their rate changes
      eligible_unlinked = create_ready_enforced_employee(first_name: "Avery", last_name: "Unlinked")
      unlinked_item = correction_run.payroll_items.create!(
        company: company,
        employee: eligible_unlinked,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 12,
        payment_delivery_method: "paper_check"
      )
      unlinked_item.calculate!
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(correction_run)).to eq([])

      EmployeeCompensationChangeService.new(
        employee: eligible_unlinked,
        pay_rate: 25.00,
        effective_on: correction_run.start_date,
        actor: admin_user,
        source: "operator",
        reason: "Corrected hourly rate"
      ).call!
      stale_list = PayrollReadinessPolicy.stale_calculation_employees_for(correction_run, stage: :approve)
      expect(stale_list.map { |entry| entry[:employee_id] }).to eq([ eligible_unlinked.id ])
      expect {
        PayPeriodLifecycleService.new(pay_period: correction_run, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Avery Unlinked/)

      # Recalculating clears the staleness; the valid linked corrective paycheck + recalculated unlinked item both approve and commit!
      unlinked_item.update!(pay_rate: eligible_unlinked.reload.default_payroll_rate_on(correction_run.end_date))
      unlinked_item.calculate!
      PayPeriodLifecycleService.new(pay_period: correction_run, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: correction_run, actor: admin_user).commit!
      expect(correction_run.reload.status).to eq("committed")
    end
  end

  describe "scoped paycheck_input_fingerprint & state-aware payment delivery" do
    it "blocks approve! and commit! when rate, wage rate, W-4 (<= pay_date), SSN, or status changes until recalculated, and ignores future W-4s and loan commits" do
      employee = create_ready_enforced_employee(first_name: "Jordan", last_name: "Fingerprint")
      period, item = build_calculated_period(employee: employee)

      expect(item.calculation_context_snapshot["paycheck_input_fingerprint"]).to be_present
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period)).to eq([])

      # Future-dated W-4 (after pay_date) does NOT mark this run stale
      add_w4!(employee, effective_on: period.pay_date + 10.days, signed_on: period.pay_date + 10.days, additional_withholding: 25)
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period)).to eq([])

      # Recording an employee loan payment (or changing its balance) does NOT mark this open run stale
      loan = EmployeeLoan.create!(
        company: company,
        employee: employee,
        name: "Cash Advance",
        tracking_mode: "balance_tracked",
        original_amount: 500,
        current_balance: 500,
        opening_balance: 500,
        balance_as_of: Date.new(2026, 9, 1),
        balance_source: "new_loan",
        payment_amount: 50,
        status: "active"
      )
      loan.record_payment!(amount: 50, date: Date.new(2026, 10, 20), recorded_by: admin_user)
      expect(loan.reload.current_balance).to eq(450)
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period)).to eq([])

      # 1. Pay rate change stales approve!
      EmployeeCompensationChangeService.new(
        employee: employee,
        pay_rate: 24.00,
        effective_on: period.start_date,
        actor: admin_user,
        source: "operator",
        reason: "Mid-cycle raise"
      ).call!
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Jordan Fingerprint/)

      # Recalculate clears it
      item.update!(pay_rate: 24.00)
      item.calculate!
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period)).to eq([])

      # 2. Wage rate change stales approve!
      EmployeeWageRate.create!(employee: employee, label: "Lead", rate: 28.00, active: true)
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Jordan Fingerprint/)
      # M4: recalculating without syncing item.pay_rate (still 24.00 while primary dated rate is now 28.00) stays stale!
      item.calculate!
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Jordan Fingerprint/)
      item.update!(pay_rate: employee.reload.default_payroll_rate_on(period.end_date))
      item.calculate!

      # 3. W-4 change effective <= pay_date stales approve!
      add_w4!(employee, effective_on: period.pay_date, signed_on: period.pay_date, additional_withholding: 30)
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Jordan Fingerprint/)
      item.calculate!

      # 4. SSN change stales approve!
      employee.update!(ssn_encrypted: "123-45-6789")
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Jordan Fingerprint/)
      item.reload.calculate!

      # 5. Approve, then mid-period termination stales commit!
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      employee.update!(status: "terminated", termination_date: period.end_date)
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Jordan Fingerprint/)
    end

    it "enforces state-aware payment delivery: calculated blocks approve! on default change until recalculated/confirmed, while approved with materialized method commits cleanly" do
      employee = create_ready_enforced_employee(first_name: "Quinn", last_name: "Delivery", payment_delivery_method: "paper_check")
      period, item = build_calculated_period(employee: employee)

      expect(item.payment_delivery_method).to eq("paper_check")
      expect(item.calculation_context_snapshot["item_payment_delivery_method"]).to eq("paper_check")
      expect(item.calculation_context_snapshot["employee_payment_default_at_calculation"]).to eq("paper_check")

      # On a CALCULATED run, changing employee.payment_delivery_method blocks approve!
      EmployeePaymentDefaultService.new(employee: employee, method: "direct_deposit", actor: admin_user).call
      expect(period.reload.status).to eq("calculated")
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Quinn Delivery/)

      # Confirming via PayrollPaymentMethodService syncs the snapshot without requiring full recalculation
      PayrollPaymentMethodService.new(payroll_item: item.reload, method: "paper_check", actor: admin_user).call
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :approve)).to eq([])

      # Changing default back to paper_check and recalculating also refreshes an un-overridden item
      EmployeePaymentDefaultService.new(employee: employee, method: "paper_check", actor: admin_user).call
      item.reload.calculate!
      expect(item.reload.payment_delivery_method).to eq("paper_check")
      EmployeePaymentDefaultService.new(employee: employee, method: "direct_deposit", actor: admin_user).call
      item.reload.calculate!
      expect(item.reload.payment_delivery_method).to eq("direct_deposit")

      # Now switch back to paper_check, recalculate, and APPROVE
      EmployeePaymentDefaultService.new(employee: employee, method: "paper_check", actor: admin_user).call
      item.reload.calculate!
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      expect(period.reload.status).to eq("approved")
      expect(item.reload.payment_delivery_method).to eq("paper_check")

      # On an APPROVED run with materialized paper_check, changing employee.payment_delivery_method
      # for future runs does NOT unapprove the run and commit! succeeds using paper_check!
      EmployeePaymentDefaultService.new(employee: employee, method: "direct_deposit", actor: admin_user).call
      expect(period.reload.status).to eq("approved")
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :commit)).to eq([])

      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!
      expect(period.reload.status).to eq("committed")
      expect(item.reload.payment_delivery_method).to eq("paper_check")
    end

    it "fails closed at commit! if a legacy approved scoped item still has payment_delivery_method NULL and the employee default drifted" do
      employee = create_ready_enforced_employee(first_name: "Robin", last_name: "LegacyNull", payment_delivery_method: "paper_check")
      period, item = build_calculated_period(employee: employee)
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!

      # Simulate legacy approved row with NULL payment_delivery_method and drifted employee default
      item.update_column(:payment_delivery_method, nil)
      employee.update_column(:payment_delivery_method, "direct_deposit")

      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Robin LegacyNull/)
    end
  end

  describe "EmployeeDocumentReadiness preservation" do
    it "seeds record-keeping rows with required_for_payroll: false for new readiness_gate_enforced hires, while still enforcing document_readiness_required: true for staff opt-ins and rehired staff hires" do
      # 1. Newly created client-managed hire defaults to document_readiness_required: false
      new_hire = create_ready_enforced_employee(first_name: "Jordan", last_name: "ClientHire", document_readiness_required: false)
      EmployeeDocumentReadiness.seed_new_hire!(employee: new_hire, actor: admin_user)
      expect(new_hire.reload.document_readiness_required?).to be(false)
      seeded_requirements = new_hire.employee_document_requirements.order(:requirement_type)
      expect(seeded_requirements.pluck(:requirement_type)).to match_array(EmployeeDocumentReadiness::DEFAULT_REQUIREMENTS.fetch("w2"))
      expect(seeded_requirements.pluck(:required_for_payroll)).to all(be(false))

      # 2. Explicit staff opt-in to document_readiness_required: true on a readiness_gate_enforced hire STILL blocks payroll
      opt_in_hire = create_ready_enforced_employee(first_name: "Sloane", last_name: "OptIn", document_readiness_required: true)
      EmployeeDocumentReadiness.seed_new_hire!(employee: opt_in_hire, actor: admin_user)
      opt_in_period, _ = build_calculated_period(employee: opt_in_hire)

      expect {
        PayPeriodLifecycleService.new(pay_period: opt_in_period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::DocumentsBlockedError, /Resolve required new-hire documents/)

      # 3. Staff-created hire with pending documents who is later rehired (readiness_gate_enforced: true) keeps document gate enforced
      staff_hire = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Devon",
        last_name: "StaffRehire",
        date_of_birth: Date.new(1992, 4, 10),
        hire_date: Date.new(2026, 1, 1),
        pay_rate: 21.00,
        pay_frequency: "biweekly",
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: false,
        document_readiness_required: false
      )
      add_w4!(staff_hire)
      EmployeeDocumentReadiness.seed_new_hire!(employee: staff_hire, actor: admin_user)
      expect(staff_hire.reload.document_readiness_required?).to be(true)

      # Simulate client-portal rehire turning on readiness_gate_enforced while preserving document_readiness_required
      staff_hire.update!(readiness_gate_enforced: true)
      rehire_period, _ = build_calculated_period(employee: staff_hire)
      expect {
        PayPeriodLifecycleService.new(pay_period: rehire_period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::DocumentsBlockedError, /Resolve required new-hire documents/)
    end
  end

  describe "unverified employee changes commit safety net" do
    it "never blocks approve!, fails closed on missing/partial/stale acknowledgement (409), writes immutable acknowledgements, and blocks supersession after commit" do
      employee = create_ready_enforced_employee(first_name: "Jordan", last_name: "Verify")
      period, _item = build_calculated_period(employee: employee)

      item_pending = EmployeeVerificationItem.create!(
        company: company,
        employee: employee,
        event_kind: "compensation_change",
        status: "pending_verification",
        affects_pay: true,
        effective_on: period.start_date,
        changed_fields: [ "pay_rate" ],
        before_values: { "pay_rate" => "18.00" },
        after_values: { "pay_rate" => "20.00" }
      )
      item_returned = EmployeeVerificationItem.create!(
        company: company,
        employee: employee,
        event_kind: "w4_change",
        status: "returned_to_client",
        affects_pay: true,
        effective_on: period.pay_date,
        changed_fields: [ "filing_status" ],
        return_note: "Please confirm W-4 signed date",
        returned_at: Time.current,
        returned_by: admin_user
      )
      # Non-pay profile edit should not block commit
      EmployeeVerificationItem.create!(
        company: company,
        employee: employee,
        event_kind: "profile_change",
        status: "pending_verification",
        affects_pay: false,
        changed_fields: [ "job_title" ]
      )

      # Unverified items do NOT block approve! or PayrollReviewPackage publishing
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      expect(period.reload.status).to eq("approved")

      # Missing acknowledgement fails closed with CommitConflict (unverified_changes_changed)
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!
      }.to raise_error(PayPeriodLifecycleService::CommitConflict) { |err|
        expect(err.code).to eq("unverified_changes_changed")
      }

      # Partial acknowledgement fails closed
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!(
          acknowledged_verification_items: [
            { id: item_pending.id, updated_at: item_pending.updated_at.utc.iso8601(6) }
          ]
        )
      }.to raise_error(PayPeriodLifecycleService::CommitConflict) { |err|
        expect(err.code).to eq("unverified_changes_changed")
      }

      # Stale updated_at fails closed
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!(
          acknowledged_verification_items: [
            { id: item_pending.id, updated_at: (item_pending.updated_at - 5.seconds).utc.iso8601(6) },
            { id: item_returned.id, updated_at: item_returned.updated_at.utc.iso8601(6) }
          ]
        )
      }.to raise_error(PayPeriodLifecycleService::CommitConflict) { |err|
        expect(err.code).to eq("unverified_changes_changed")
      }

      # Exact snapshot acknowledgement commits cleanly
      service = PayPeriodLifecycleService.new(pay_period: period, actor: admin_user)
      service.commit!(
        acknowledged_verification_items: [
          { id: item_pending.id, updated_at: item_pending.updated_at.utc.iso8601(6) },
          { id: item_returned.id, updated_at: item_returned.updated_at.utc.iso8601(6) }
        ]
      )
      expect(period.reload.status).to eq("committed")
      expect(service.acknowledged_verification_items.pluck(:id)).to contain_exactly(item_pending.id, item_returned.id)

      # Immutable acknowledgement rows written; items remain unverified and reject supersession
      acks = PayPeriodVerificationAcknowledgement.where(pay_period_id: period.id)
      expect(acks.count).to eq(2)
      expect(item_pending.reload.status).to eq("pending_verification")
      expect(item_returned.reload.status).to eq("returned_to_client")
      expect(item_pending.acknowledged_in_committed_run?).to be(true)

      item_pending.status = "superseded"
      expect(item_pending).not_to be_valid
      expect(item_pending.errors[:status]).to include("cannot be superseded after being acknowledged in a committed pay run")

      ack = acks.first
      expect(ack.update(item_status_snapshot: "returned_to_client")).to be(false)
      expect(ack.destroy).to be(false)

      # L8: DB-level append-only triggers also reject UPDATE and DELETE bypassing ActiveRecord callbacks
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          PayPeriodVerificationAcknowledgement.where(id: ack.id).update_all(item_status_snapshot: "returned_to_client")
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /pay_period_verification_acknowledgements is append-only/)
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          PayPeriodVerificationAcknowledgement.where(id: ack.id).delete_all
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /pay_period_verification_acknowledgements is append-only/)
    end
  end

  describe "additional PR 2 review regression suites (M3, M4 multi-rate, M5, L6, intake/time-tracking guards, payment override)" do
    it "guards PayrollIntake::ApplyService and TimeTracking::ApplyImportService against Incomplete hires" do
      incomplete = create_incomplete_enforced_employee(first_name: "Morgan", last_name: "Intake")
      ready = create_ready_enforced_employee(first_name: "Jordan", last_name: "Intake")
      workweek = CompanyWorkweek.create!(
        company: company,
        starts_on_weekday: 0,
        starts_at_minutes: 0,
        timezone: "Pacific/Guam",
        source: "operator_confirmed",
        confirmation_status: "confirmed",
        effective_on: Date.new(2026, 1, 1),
        confirmed_by: admin_user,
        confirmed_at: Time.current,
        notes: "Confirmed workweek"
      )
      period = create(
        :pay_period,
        company: company,
        company_workweek: workweek,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )

      # 1. PayrollIntake::ApplyService skips Incomplete and applies Ready
      session = create(
        :payroll_intake_session,
        company: company,
        pay_period: period,
        status: "previewed",
        evidence_snapshot: {
          "workweek" => PayrollIntake::WorkweekEvidence.new(pay_period: period).capture!,
          "source_period" => { "start_date" => period.start_date.iso8601, "end_date" => period.end_date.iso8601 }
        }
      )
      row_incomplete = create(:payroll_intake_row, payroll_intake_session: session, employee: incomplete, source_employee_name: incomplete.full_name, week1_hours: 16, week2_hours: 16, regular_hours: 32)
      row_ready = create(:payroll_intake_row, payroll_intake_session: session, employee: ready, source_employee_name: ready.full_name, week1_hours: 20, week2_hours: 20, regular_hours: 40)

      intake_result = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [
          { id: row_incomplete.id, employee_id: incomplete.id, disposition: "included" },
          { id: row_ready.id, employee_id: ready.id, disposition: "included" }
        ],
        actor: admin_user
      ).call

      expect(intake_result[:errors]).to eq([])
      expect(intake_result[:applied].map { |r| r[:employee_id] }).to eq([ ready.id ])
      expect(intake_result[:skipped].size).to eq(1)
      expect(intake_result[:skipped].first).to include(
        row_id: row_incomplete.id,
        employee_id: incomplete.id,
        code: "employee_readiness_incomplete"
      )
      expect(intake_result[:skipped].first[:reason]).to include("W-4 missing")
      expect(period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)

      # 2. TimeTracking::ApplyImportService skips Incomplete on non-finalized batch and errors on finalized batch
      tt_period = create(
        :pay_period,
        company: company,
        company_workweek: workweek,
        start_date: Date.new(2026, 11, 15),
        end_date: Date.new(2026, 11, 28),
        pay_date: Date.new(2026, 12, 4),
        status: "draft"
      )
      source = create(:time_tracking_source, company: company)
      base_payload = {
        "schema_version" => "1.0",
        "validation_version" => "time_summary_v1",
        "start_date" => tt_period.start_date.iso8601,
        "end_date" => tt_period.end_date.iso8601,
        "legal_workweek" => {
          "company_workweek_id" => workweek.id,
          "starts_on_weekday" => workweek.starts_on_weekday,
          "starts_at_minutes" => workweek.starts_at_minutes,
          "timezone" => workweek.timezone
        },
        "rows" => [
          {
            "source_user_id" => "u-inc",
            "source_email" => "inc@example.com",
            "source_display_name" => incomplete.full_name,
            "employee_id" => incomplete.id,
            "regular_hours" => 24.0,
            "overtime_hours" => 0.0,
            "categories" => [ { "source_category_id" => "reg", "name" => "Regular", "regular_hours" => 24.0, "overtime_hours" => 0.0, "total_hours" => 24.0 } ],
            "warnings" => []
          },
          {
            "source_user_id" => "u-rdy",
            "source_email" => "rdy@example.com",
            "source_display_name" => ready.full_name,
            "employee_id" => ready.id,
            "regular_hours" => 40.0,
            "overtime_hours" => 0.0,
            "categories" => [ { "source_category_id" => "reg", "name" => "Regular", "regular_hours" => 40.0, "overtime_hours" => 0.0, "total_hours" => 40.0 } ],
            "warnings" => []
          }
        ]
      }
      tt_import = TimeTrackingImport.create!(
        pay_period: tt_period,
        time_tracking_source: source,
        start_date: tt_period.start_date,
        end_date: tt_period.end_date,
        fetch_start_date: tt_period.start_date,
        fetch_end_date: tt_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("tt-non-finalized"),
        processed_payload: base_payload
      )

      tt_result = TimeTracking::ApplyImportService.new(import: tt_import, mappings: [], applied_by: admin_user).call
      expect(tt_result[:errors]).to eq([])
      expect(tt_result[:applied].map { |r| r[:employee_id] }).to eq([ ready.id ])
      expect(tt_result[:skipped].first).to include(
        employee_id: incomplete.id,
        code: "employee_readiness_incomplete"
      )
      expect(tt_period.payroll_items.exists?(employee_id: incomplete.id)).to be(false)
    end

    it "does NOT exempt a late-hours adjustment before it is applied or when no origin allocations exist (M3)" do
      ready_origin = create_ready_enforced_employee(first_name: "Origin", last_name: "Worker")
      origin_period, _ = build_calculated_period(
        employee: ready_origin,
        start_date: Date.new(2026, 10, 1),
        end_date: Date.new(2026, 10, 14),
        pay_date: Date.new(2026, 10, 20)
      )
      PayPeriodLifecycleService.new(pay_period: origin_period, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: origin_period, actor: admin_user).commit!

      late_hire = create_incomplete_enforced_employee(first_name: "Riley", last_name: "Unapplied")
      source = create(:time_tracking_source, company: company)

      # Case 1: Late-hours run BEFORE it is applied (applied_at: nil, in selection_snapshot, no allocations)
      unapplied_adj, unapplied_item = build_calculated_period(
        employee: late_hire,
        run_purpose: "adjustment",
        includes_base_salary: false,
        includes_recurring_items: false,
        start_date: origin_period.start_date,
        end_date: origin_period.end_date,
        pay_date: Date.new(2026, 11, 20)
      )
      late_run = TimeTrackingLateHoursRun.create!(
        company: company,
        time_tracking_source: source,
        origin_pay_period: origin_period,
        adjustment_pay_period: unapplied_adj,
        created_by: admin_user,
        command_id: SecureRandom.uuid,
        state: "pending",
        applied_at: nil,
        request_payload: {},
        rate_snapshot: [],
        selection_snapshot: [ { "id" => "case-unapplied", "payroll_employee_id" => late_hire.id } ]
      )

      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: unapplied_adj.reload, employee: late_hire, payroll_item: unapplied_item)).to be_present
      expect {
        PayPeriodLifecycleService.new(pay_period: unapplied_adj, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)

      # Case 2: Late-hours run marked applied, but with NO origin-period allocations -> STILL blocked!
      late_run.update!(state: "applied", applied_at: Time.current)
      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: unapplied_adj.reload, employee: late_hire, payroll_item: unapplied_item)).to be_present
      expect {
        PayPeriodLifecycleService.new(pay_period: unapplied_adj, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)
    end

    it "catches stale wage-rate allocations even after item.calculate! without repricing (M4 multi-rate)" do
      employee = create_ready_enforced_employee(first_name: "Multi", last_name: "RateM4", pay_rate: 20.00)
      primary_rate = EmployeeWageRate.create!(employee: employee, label: "Server", rate: 20.00, is_primary: true, active: true)
      lead_rate = EmployeeWageRate.create!(employee: employee, label: "Lead", rate: 25.00, is_primary: false, active: true)

      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 30,
        payment_delivery_method: "paper_check",
        wage_rate_hours: [
          { employee_wage_rate_id: primary_rate.id, label: "Server", rate: 20.00, regular_hours: 20, overtime_hours: 0, is_primary: true, active: true },
          { employee_wage_rate_id: lead_rate.id, label: "Lead", rate: 25.00, regular_hours: 10, overtime_hours: 0, is_primary: false, active: true }
        ]
      )
      item.calculate!
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :approve)).to eq([])

      # Raise the Lead wage rate effective for this period
      EmployeeCompensationChangeService.new(
        employee: employee,
        wage_rates: [
          { id: primary_rate.id, label: "Server", rate: 20.00, is_primary: true, active: true },
          { id: lead_rate.id, label: "Lead", rate: 30.00, is_primary: false, active: true }
        ],
        effective_on: period.start_date,
        actor: admin_user,
        source: "operator",
        reason: "Lead rate raise"
      ).call!

      # Calling item.calculate! without repricing wage_rate_hours refreshes fingerprint on old $25 Lead allocation -> MUST still be stale!
      item.reload.calculate!
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve).map { |r| r[:employee_id] }).to eq([ employee.id ])
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Multi RateM4/)

      # Repricing wage_rate_hours and recalculating clears staleness
      PayrollWageRateInput.reprice_saved!(item.reload)
      item.calculate!
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve)).to eq([])
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      expect(period.reload.status).to eq("approved")
    end

    it "marks gated calculated/approved items without a fingerprint as stale until recalculated (M5)" do
      employee = create_ready_enforced_employee(first_name: "PreGate", last_name: "Worker")
      period, item = build_calculated_period(employee: employee)

      # Simulate an item calculated before the employee became readiness_gate_enforced (no fingerprint in snapshot)
      item.update_column(:calculation_context_snapshot, item.calculation_context_snapshot.except("paycheck_input_fingerprint"))

      stale = PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve)
      expect(stale.map { |r| r[:employee_id] }).to eq([ employee.id ])
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*PreGate Worker/)

      # Also fails closed at commit! if status is approved
      period.update_column(:status, "approved")
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).commit!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*PreGate Worker/)

      # Recalculating writes the fingerprint and clears staleness
      period.update_column(:status, "calculated")
      item.reload.calculate!
      expect(item.reload.calculation_context_snapshot["paycheck_input_fingerprint"]).to be_present
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve)).to eq([])
    end

    it "syncs payment-method snapshot in PayrollPaymentMethodService#change_uncommitted! and preserves per-item override across recalculation" do
      employee = create_ready_enforced_employee(first_name: "Override", last_name: "Survivor", payment_delivery_method: "paper_check")
      period, item = build_calculated_period(employee: employee)

      # Change employee default to direct_deposit -> calculated run becomes stale for approve!
      EmployeePaymentDefaultService.new(employee: employee, method: "direct_deposit", actor: admin_user).call
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve).map { |r| r[:employee_id] }).to eq([ employee.id ])

      # Staff explicitly confirms paper_check for this paycheck via PayrollPaymentMethodService
      PayrollPaymentMethodService.new(payroll_item: item.reload, method: "paper_check", actor: admin_user).call
      snapshot = item.reload.calculation_context_snapshot.to_h
      expect(snapshot["item_payment_delivery_method"]).to eq("paper_check")
      expect(snapshot["employee_payment_default_at_calculation"]).to eq("direct_deposit")
      expect(snapshot["payment_delivery_method_overridden"]).to be(true)
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve)).to eq([])

      # Recalculating preserves the per-item paper_check override instead of clobbering it with direct_deposit
      item.reload.calculate!
      expect(item.reload.payment_delivery_method).to eq("paper_check")
      expect(item.calculation_context_snapshot.to_h["payment_delivery_method_overridden"]).to be(true)
      expect(item.calculation_context_snapshot.to_h["item_payment_delivery_method"]).to eq("paper_check")
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period.reload, stage: :approve)).to eq([])
    end

    it "caches CompanyFeatures per company inside with_cache and short-circuits ungated companies without preloading associations (L6)" do
      legacy = create(:employee, :hourly, company: company, pay_rate: 20.00, readiness_gate_enforced: false)
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: legacy,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )

      # CompanyFeatures.with_cache hits ClientOperatingProfile.for_date only once per company
      for_date_calls = 0
      allow(ClientOperatingProfile).to receive(:for_date).and_wrap_original do |method, *args|
        for_date_calls += 1 if args.first == company.id
        method.call(*args)
      end
      CompanyFeatures.with_cache do
        CompanyFeatures.for(company)
        CompanyFeatures.for(company)
        item.calculate!
      end
      expect(for_date_calls).to eq(1)

      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      # Ungated company short-circuits without querying employee_w4_elections / employee_deductions / etc.
      queries = []
      callback = lambda do |_name, _started, _finished, _id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        CompanyFeatures.with_cache do
          expect(PayrollReadinessPolicy.readiness_excluded_employees_for(period)).to eq([])
          expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :approve)).to eq([])
          expect(Employee.where(company_id: company.id).eligible_for_payroll_run(period).pluck(:id)).to include(legacy.id)
        end
      end

      expect(queries.grep(/employee_w4_elections|employee_deductions|employee_payroll_fields|employee_retirement_elections|employee_readiness_overrides/)).to be_empty
    end

    it "blocks approve! even if company_has_gated_employees? was false before flipping readiness_gate_enforced via update_all (round 2 medium 2)" do
      # Incomplete employee (no W-4) starts ungated so the item can be calculated
      incomplete = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Uncached",
        last_name: "FlipGate",
        date_of_birth: Date.new(1994, 5, 14),
        hire_date: Date.new(2026, 1, 1),
        pay_rate: 20.00,
        pay_frequency: "biweekly",
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: false
      )
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: incomplete,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )
      item.calculate!
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      # Prime outer cache as false, flip readiness_gate_enforced with update_all (skipping callbacks), then approve!
      CompanyFeatures.with_cache do
        expect(PayrollReadinessPolicy.company_has_gated_employees?(company.id)).to be(false)
        expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(false)

        Employee.where(id: incomplete.id).update_all(readiness_gate_enforced: true)

        expect {
          PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
        }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /W-4 missing/)
      end
      expect(period.reload.status).to eq("calculated")
    end

    it "blocks approve! on stale unfingerprinted items after update_all flips readiness_gate_enforced or direct SQL enables client_managed (round 2 medium 2)" do
      ready_initially_ungated = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Ready",
        last_name: "Unfingerprinted",
        date_of_birth: Date.new(1994, 5, 14),
        hire_date: Date.new(2026, 1, 1),
        pay_rate: 20.00,
        pay_frequency: "biweekly",
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: false
      )
      EmployeeW4Election.create!(
        EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
          company: company,
          employee: ready_initially_ungated,
          effective_on: Date.new(2026, 1, 1),
          w4_signed_on: Date.new(2026, 1, 1),
          w4_form_version: 2020,
          source: "client_direct",
          reason: "Test W-4"
        )
      )
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: ready_initially_ungated,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )
      item.calculate!
      expect(item.reload.calculation_context_snapshot.to_h).not_to have_key("paycheck_input_fingerprint")
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      # Case 1: update_all flips readiness_gate_enforced -> stale_calculation_employees_for catches missing fingerprint
      CompanyFeatures.with_cache do
        expect(PayrollReadinessPolicy.company_has_gated_employees?(company.id)).to be(false)
        Employee.where(id: ready_initially_ungated.id).update_all(readiness_gate_enforced: true)

        expect {
          PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
        }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Ready Unfingerprinted/)
      end

      # Reset gate to false and test Case 2: CompanyFeatures cached as approval_first BEFORE lock,
      # then client_managed enabled directly in DB -> approve! opens a fresh cache inside the lock and blocks!
      Employee.where(id: ready_initially_ungated.id).update_all(readiness_gate_enforced: false)
      stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])
      CompanyFeatures.with_cache do
        expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(false)

        now = Time.current
        ClientOperatingProfile.insert_all!([
          {
            company_id: company.id,
            effective_on: Date.new(2026, 1, 1),
            version: 1,
            offering: "payroll_portals",
            hours_source: "manual",
            client_portal_enabled: true,
            employee_portal_enabled: false,
            lifecycle_mode_activated_at: now,
            options: OperatingProfileCatalog.default_options.deep_merge(
              "client_portal" => { "employee_lifecycle_mode" => "client_managed" }
            ),
            reason: "Direct insert bypassing callbacks",
            created_at: now,
            updated_at: now
          }
        ])

        expect {
          PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
        }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Ready Unfingerprinted/)
      end
      expect(period.reload.status).to eq("calculated")
    end
  end

  describe "CodeRabbit PR #685 review fixes and regression coverage" do
    it "carries a future-effective off-roster new_hire item past the prior commit cutoff until acknowledged, while preserving on_run behavior" do
      active_worker = create_ready_enforced_employee(first_name: "Taylor", last_name: "Active")
      future_hire = create_incomplete_enforced_employee(
        first_name: "Casey",
        last_name: "FutureHire",
        hire_date: Date.new(2026, 12, 1)
      )

      new_hire_item = EmployeeVerificationItem.create!(
        company: company,
        employee: future_hire,
        event_kind: "new_hire",
        status: "pending_verification",
        affects_pay: true,
        effective_on: Date.new(2026, 12, 1),
        created_at: Time.zone.local(2026, 11, 20, 10, 0, 0),
        updated_at: Time.zone.local(2026, 11, 20, 10, 0, 0)
      )

      # Run 1 (Nov 16 - Nov 30): Dec 1 new_hire is future-effective, so excluded and not acknowledged
      nov_period, _ = build_calculated_period(
        employee: active_worker,
        start_date: Date.new(2026, 11, 16),
        end_date: Date.new(2026, 11, 30),
        pay_date: Date.new(2026, 12, 4)
      )
      expect(PayPeriodUnverifiedChanges.new(nov_period).relation.pluck(:id)).to eq([])
      PayPeriodLifecycleService.new(pay_period: nov_period, actor: admin_user).approve!
      PayPeriodLifecycleService.new(pay_period: nov_period, actor: admin_user).commit!
      expect(nov_period.reload.status).to eq("committed")

      # Run 2 (Dec 1 - Dec 15): future_hire is STILL off-roster, effective_on <= Dec 15,
      # created_at < nov_period.committed_at, and never acknowledged -> MUST surface and block commit!
      dec_period, _ = build_calculated_period(
        employee: active_worker,
        start_date: Date.new(2026, 12, 1),
        end_date: Date.new(2026, 12, 15),
        pay_date: Date.new(2026, 12, 18)
      )
      expect(PayPeriodUnverifiedChanges.new(dec_period).relation.pluck(:id)).to eq([ new_hire_item.id ])
      PayPeriodLifecycleService.new(pay_period: dec_period, actor: admin_user).approve!

      expect {
        PayPeriodLifecycleService.new(pay_period: dec_period, actor: admin_user).commit!
      }.to raise_error(PayPeriodLifecycleService::CommitConflict) { |err|
        expect(err.code).to eq("unverified_changes_changed")
      }

      PayPeriodLifecycleService.new(pay_period: dec_period, actor: admin_user).commit!(
        acknowledged_verification_items: [
          { id: new_hire_item.id, updated_at: new_hire_item.updated_at.utc.iso8601(6) }
        ]
      )
      expect(dec_period.reload.status).to eq("committed")

      # Run 3 (Dec 16 - Dec 31): once acknowledged on a committed run, an unchanged off-roster
      # lifecycle item is no longer surfaced in lifecycle_scope...
      late_dec_period, _ = build_calculated_period(
        employee: active_worker,
        start_date: Date.new(2026, 12, 16),
        end_date: Date.new(2026, 12, 31),
        pay_date: Date.new(2026, 12, 31)
      )
      expect(PayPeriodUnverifiedChanges.new(late_dec_period).relation.pluck(:id)).to eq([])

      # ...but if the employee IS on the run (on_run), the open item STILL surfaces!
      late_dec_period.payroll_items.create!(
        company: company,
        employee: future_hire,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 10,
        payment_delivery_method: "paper_check"
      )
      expect(PayPeriodUnverifiedChanges.new(late_dec_period).relation.pluck(:id)).to eq([ new_hire_item.id ])
    end

    it "binds paycheck_input_fingerprint to the W-4 election used for withholding even when a newer W-4 commits before snapshot capture" do
      employee = create_ready_enforced_employee(first_name: "Morgan", last_name: "ConcurrentW4")
      original_w4 = employee.w4_election_on(Date.new(2026, 11, 20))
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 25.00,
        hours_worked: 80,
        payment_delivery_method: "paper_check"
      )

      newer_w4 = nil
      allow(PayrollCalculationContext).to receive(:capture).and_wrap_original do |original, **kwargs|
        newer_w4 = EmployeeW4Election.create!(
          EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
            company: company,
            employee: employee,
            filing_status: "married",
            effective_on: Date.new(2026, 11, 10),
            w4_signed_on: Date.new(2026, 11, 10),
            w4_form_version: 2020,
            source: "client_direct",
            reason: "Concurrent W-4 change during calculation"
          )
        )
        employee.association(:employee_w4_elections).reset
        original.call(**kwargs)
      end

      item.calculate!
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      expect(item.reload.tax_rule_snapshot.dig("w4", "election_id")).to eq(original_w4.id)
      expected_old_fp = PayrollCalculationContext.paycheck_input_fingerprint(
        employee: employee,
        pay_period: period,
        w4_election: original_w4,
        w4_profile: original_w4.profile_attributes
      )
      live_new_fp = PayrollCalculationContext.paycheck_input_fingerprint(employee: employee, pay_period: period)

      expect(item.calculation_context_snapshot["paycheck_input_fingerprint"]).to eq(expected_old_fp)
      expect(live_new_fp).not_to eq(expected_old_fp)
      expect(newer_w4).to be_present

      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Morgan ConcurrentW4/)
    end

    it "scoping retirement inputs to the paycheck pay_date/tax_year ignores future elections and unrelated tax years while detecting applicable changes" do
      AnnualRetirementLimit.find_or_create_by!(tax_year: 2026) do |limit|
        limit.elective_deferral_limit = 23_500
        limit.catch_up_limit = 7_500
        limit.enhanced_catch_up_limit = 11_250
        limit.roth_catch_up_wage_threshold = 145_000
        limit.annual_additions_limit = 70_000
        limit.compensation_limit = 350_000
        limit.source_name = "IRS Notice"
        limit.source_url = "https://www.irs.gov"
      end

      employee = create_ready_enforced_employee(first_name: "Avery", last_name: "Retirement")
      EmployeeRetirementElection.create!(
        company: company,
        employee: employee,
        effective_on: Date.new(2026, 1, 1),
        plan_name: "401k Plan",
        eligible: true,
        participating: true,
        traditional_contribution_type: "percentage",
        traditional_rate: 0.04,
        roth_contribution_type: "percentage",
        roth_rate: 0,
        source: "staff",
        reason: "Initial election"
      )
      period, item = build_calculated_period(employee: employee)
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      original_fp = item.reload.calculation_context_snapshot.fetch("paycheck_input_fingerprint")

      # Adding a future-effective retirement election (after pay_date) and a 2027 year input must NOT invalidate the approved 2026 run
      EmployeeRetirementElection.create!(
        company: company,
        employee: employee,
        effective_on: period.pay_date + 10.days,
        plan_name: "401k Plan",
        eligible: true,
        participating: true,
        traditional_contribution_type: "percentage",
        traditional_rate: 0.06,
        roth_contribution_type: "percentage",
        roth_rate: 0,
        source: "staff",
        reason: "Next month rate increase"
      )
      EmployeeRetirementYearInput.create!(
        company: company,
        employee: employee,
        tax_year: 2027,
        prior_year_wage_status: "unknown",
        source_reference: "2027-admin-note",
        reason: "Next year setup"
      )

      expect(PayrollCalculationContext.paycheck_input_fingerprint(employee: employee.reload, pay_period: period)).to eq(original_fp)
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :commit)).to eq([])

      # Adding an election effective on or before pay_date DOES invalidate the run
      EmployeeRetirementElection.create!(
        company: company,
        employee: employee,
        effective_on: period.pay_date,
        plan_name: "401k Plan",
        eligible: true,
        participating: true,
        traditional_contribution_type: "percentage",
        traditional_rate: 0.05,
        roth_contribution_type: "percentage",
        roth_rate: 0,
        source: "staff",
        reason: "Same-day election update"
      )
      expect(PayrollCalculationContext.paycheck_input_fingerprint(employee: employee.reload, pay_period: period)).not_to eq(original_fp)
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :commit).map { |e| e[:employee_id] }).to eq([ employee.id ])
    end

    it "reuses preloaded associations and caches the tax-ID HMAC key during staleness scans" do
      emp1 = create_ready_enforced_employee(first_name: "Preload", last_name: "One")
      emp2 = create_ready_enforced_employee(first_name: "Preload", last_name: "Two")
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      [ emp1, emp2 ].each do |emp|
        item = period.payroll_items.create!(
          company: company,
          employee: emp,
          employment_type: "hourly",
          pay_rate: 20.00,
          hours_worked: 40,
          payment_delivery_method: "paper_check"
        )
        item.calculate!
      end
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      # Warm key cache once, then confirm repeated scans do not re-derive PBKDF2 keys or re-query preloaded associations
      PayrollCalculationContext.paycheck_input_fingerprint(employee: emp1, pay_period: period)
      expect(ActiveSupport::KeyGenerator).not_to receive(:new)

      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        queries << payload[:sql]
      end

      result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :approve)
      end

      expect(result).to eq([])
      deduction_queries = queries.select { |sql| sql.include?('FROM "employee_deductions"') }
      field_queries = queries.select { |sql| sql.include?('FROM "employee_payroll_fields"') }
      retirement_queries = queries.select { |sql| sql.include?('FROM "employee_retirement_elections"') || sql.include?('FROM "employee_retirement_year_inputs"') }
      expect(deduction_queries.size).to be <= 1
      expect(field_queries.size).to be <= 1
      expect(retirement_queries.size).to be <= 2
    end

    it "issues the replacement client review AFTER syncing calculation_context_snapshot in PayrollPaymentMethodService" do
      company.update!(client_payroll_approval_required: true)
      employee = create_ready_enforced_employee(first_name: "Quinn", last_name: "ReviewSync", payment_delivery_method: "paper_check")
      period, item = build_calculated_period(employee: employee)
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      initial_package = period.payroll_review_packages.current.first!

      # 1. Change item method with update_employee_default: true on an approved fingerprinted run
      PayrollPaymentMethodService.new(
        payroll_item: item,
        method: "direct_deposit",
        actor: admin_user,
        update_employee_default: true
      ).call

      item.reload
      period.reload
      expect(period.status).to eq("calculated")
      expect(item.payment_delivery_method).to eq("direct_deposit")
      expect(employee.reload.payment_delivery_method).to eq("direct_deposit")
      expect(item.calculation_context_snapshot["item_payment_delivery_method"]).to eq("direct_deposit")
      expect(item.calculation_context_snapshot["employee_payment_default_at_calculation"]).to eq("direct_deposit")
      expect(item.calculation_context_snapshot["payment_delivery_method_overridden"]).to be(false)

      replacement_package = period.payroll_review_packages.current.order(revision: :desc).first!
      expect(replacement_package.id).not_to eq(initial_package.id)
      expect {
        PayrollReview::RevisionService.new(pay_period: period, actor: admin_user).verify_current_checksum!(replacement_package)
      }.not_to raise_error

      # Approving and publishing must succeed without StaleRevisionError
      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      expect(period.reload.status).to eq("approved")

      # 2. Change item method back to paper_check WITHOUT changing employee default (per-item override)
      PayrollPaymentMethodService.new(
        payroll_item: item.reload,
        method: "paper_check",
        actor: admin_user,
        update_employee_default: false
      ).call

      override_package = period.reload.payroll_review_packages.current.order(revision: :desc).first!
      expect(item.reload.calculation_context_snapshot["payment_delivery_method_overridden"]).to be(true)
      expect {
        PayrollReview::RevisionService.new(pay_period: period, actor: admin_user).verify_current_checksum!(override_package)
      }.not_to raise_error
    end

    it "blocks approval when a label-only wage_rate_hours entry no longer resolves to any dated employee wage rate" do
      employee = create_ready_enforced_employee(first_name: "Jamie", last_name: "LabelOnly")
      primary_rate = employee.employee_wage_rates.create!(label: "Regular", rate: 20.00, is_primary: true, active: true)
      secondary_rate = employee.employee_wage_rates.create!(label: "Old Shift", rate: 28.00, is_primary: false, active: true)

      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        payment_delivery_method: "paper_check"
      )
      item.wage_rate_hours = [
        { employee_wage_rate_id: primary_rate.id, label: "Regular", rate: 20.00, regular_hours: 30, overtime_hours: 0, is_primary: true, active: true },
        { employee_wage_rate_id: nil, label: "Old Shift", rate: 28.00, regular_hours: 10, overtime_hours: 0, is_primary: false, active: true }
      ]
      item.calculate!
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      # While "Old Shift" resolves at $28.00, item is NOT stale
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :approve)).to eq([])

      # Rename the secondary rate (or remove the label) and recalculate standalone WITHOUT repricing the label-only entry
      secondary_rate.update_columns(label: "New Shift", rate: 32.00)
      EmployeeWageRateVersion.where(employee_wage_rate_id: secondary_rate.id).update_all(label: "New Shift", rate: 32.00)
      item.reload.calculate!

      # Approval MUST fail closed even after standalone calculate! because "Old Shift" no longer resolves to any dated rate
      stale = PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :approve)
      expect(stale.map { |entry| entry[:employee_id] }).to eq([ employee.id ])
      expect {
        PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate payroll.*Jamie LabelOnly/)
    end

    it "clears results[:applied] when TimeTracking::ApplyImportService rolls back due to an error" do
      ready = create_ready_enforced_employee(first_name: "Ready", last_name: "Rollback")
      incomplete = create_incomplete_enforced_employee(first_name: "Blocked", last_name: "Rollback")
      workweek = CompanyWorkweek.create!(
        company: company,
        starts_on_weekday: 0,
        starts_at_minutes: 0,
        timezone: "Pacific/Guam",
        source: "operator_confirmed",
        confirmation_status: "confirmed",
        effective_on: Date.new(2026, 1, 1),
        confirmed_by: admin_user,
        confirmed_at: Time.current,
        notes: "Confirmed workweek"
      )
      tt_period = create(
        :pay_period,
        company: company,
        company_workweek: workweek,
        start_date: Date.new(2026, 11, 15),
        end_date: Date.new(2026, 11, 28),
        pay_date: Date.new(2026, 12, 4),
        status: "draft"
      )
      source = create(:time_tracking_source, company: company)
      # Row 1 applies cleanly, Row 2 errors (unmapped employee) -> whole batch rolls back and applied MUST be empty
      payload = {
        "schema_version" => "1.0",
        "validation_version" => "time_summary_v1",
        "start_date" => tt_period.start_date.iso8601,
        "end_date" => tt_period.end_date.iso8601,
        "legal_workweek" => {
          "company_workweek_id" => workweek.id,
          "starts_on_weekday" => workweek.starts_on_weekday,
          "starts_at_minutes" => workweek.starts_at_minutes,
          "timezone" => workweek.timezone
        },
        "rows" => [
          {
            "source_user_id" => "u-ready",
            "source_email" => "ready@example.com",
            "source_display_name" => ready.full_name,
            "employee_id" => ready.id,
            "regular_hours" => 40.0,
            "overtime_hours" => 0.0,
            "categories" => [ { "source_category_id" => "reg", "name" => "Regular", "regular_hours" => 40.0, "overtime_hours" => 0.0, "total_hours" => 40.0 } ],
            "warnings" => []
          },
          {
            "source_user_id" => "u-missing",
            "source_email" => "missing@example.com",
            "source_display_name" => incomplete.full_name,
            "employee_id" => nil,
            "regular_hours" => 16.0,
            "overtime_hours" => 0.0,
            "categories" => [ { "source_category_id" => "reg", "name" => "Regular", "regular_hours" => 16.0, "overtime_hours" => 0.0, "total_hours" => 16.0 } ],
            "warnings" => []
          }
        ]
      }
      tt_import = TimeTrackingImport.create!(
        pay_period: tt_period,
        time_tracking_source: source,
        start_date: tt_period.start_date,
        end_date: tt_period.end_date,
        fetch_start_date: tt_period.start_date,
        fetch_end_date: tt_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("tt-rollback-clear-applied"),
        processed_payload: payload
      )

      result = TimeTracking::ApplyImportService.new(import: tt_import, mappings: [], applied_by: admin_user).call
      expect(result[:errors]).not_to be_empty
      expect(result[:applied]).to eq([])
      expect(tt_period.payroll_items.count).to eq(0)
      expect(tt_import.reload.status).to eq("previewed")
    end

    it "keeps approval_first companies unchanged across calculation, payment-method service, and stale-rate checks" do
      legacy_employee = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Legacy",
        last_name: "ApprovalFirst",
        date_of_birth: Date.new(1990, 1, 1),
        hire_date: Date.new(2026, 1, 1),
        pay_rate: 20.00,
        pay_frequency: "biweekly",
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: false
      )
      add_w4!(legacy_employee)
      period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 11, 1),
        end_date: Date.new(2026, 11, 14),
        pay_date: Date.new(2026, 11, 20),
        status: "draft"
      )
      item = period.payroll_items.create!(
        company: company,
        employee: legacy_employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        payment_delivery_method: "direct_deposit"
      )
      item.wage_rate_hours = [
        { employee_wage_rate_id: nil, label: "Unmatched Legacy Label", rate: 20.00, regular_hours: 40, overtime_hours: 0, is_primary: true, active: true }
      ]
      item.calculate!
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

      # Explicit payment method preserved (shared rule does not overwrite approval_first item), and no scoped snapshot keys written
      expect(item.reload.payment_delivery_method).to eq("direct_deposit")
      expect(item.calculation_context_snapshot.keys).not_to include(
        "paycheck_input_fingerprint",
        "item_payment_delivery_method",
        "employee_payment_default_at_calculation",
        "payment_delivery_method_overridden"
      )
      expect(PayrollReadinessPolicy.stale_calculation_employees_for(period, stage: :approve)).to eq([])

      PayrollPaymentMethodService.new(
        payroll_item: item,
        method: "paper_check",
        actor: admin_user,
        update_employee_default: false
      ).call
      expect(item.reload.calculation_context_snapshot.keys).not_to include("paycheck_input_fingerprint", "item_payment_delivery_method")

      PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!
      expect(period.reload.status).to eq("approved")
    end
  end
end

RSpec.describe "Concurrent commit verification acknowledgements (L8)" do
  self.use_transactional_tests = false

  it "serializes concurrent commit! calls under the company/period lock and writes exactly one acknowledgement row" do
    verification_tables = ensure_verified_test_tax_years(2026)
    organization = create(:organization, slug: "concurrent-lock-#{SecureRandom.hex(6)}")
    company = create(:company, organization: organization, name: "Concurrent Lock Co", auto_create_fit_check: false)
    admin_user = create(:user, company: company, organization: organization, role: "admin")
    employee = create(
      :employee,
      :hourly,
      company: company,
      department: nil,
      first_name: "Jordan",
      last_name: "Concurrent",
      date_of_birth: Date.new(1994, 5, 14),
      hire_date: Date.new(2026, 1, 1),
      pay_rate: 20.00,
      pay_frequency: "biweekly",
      payment_delivery_method: "paper_check",
      readiness_gate_enforced: true
    )
    EmployeeW4Election.create!(
      EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
        company: company,
        employee: employee,
        effective_on: Date.new(2026, 1, 1),
        w4_signed_on: Date.new(2026, 1, 1),
        w4_form_version: 2020,
        source: "client_direct",
        reason: "Test W-4"
      )
    )
    period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 14),
      pay_date: Date.new(2026, 11, 20),
      status: "draft"
    )
    item = period.payroll_items.create!(
      company: company,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20.00,
      hours_worked: 40,
      payment_delivery_method: "paper_check"
    )
    item.calculate!
    period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin_user.id)

    verification_item = EmployeeVerificationItem.create!(
      company: company,
      employee: employee,
      event_kind: "compensation_change",
      status: "pending_verification",
      affects_pay: true,
      effective_on: period.start_date,
      changed_fields: [ "pay_rate" ]
    )
    PayPeriodLifecycleService.new(pay_period: period, actor: admin_user).approve!

    ack_payload = [ { id: verification_item.id, updated_at: verification_item.updated_at.utc.iso8601(6) } ]
    first_lock_acquired = Queue.new
    second_attempting = Queue.new
    release_first = Queue.new
    outcomes = {}
    outcomes_mutex = Mutex.new

    first_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service = PayPeriodLifecycleService.new(pay_period: PayPeriod.find(period.id), actor: User.find(admin_user.id))
        service.define_singleton_method(:validate_verification_acknowledgements!) do |acknowledged_items|
          first_lock_acquired << true
          release_first.pop(timeout: 5)
          super(acknowledged_items)
        end
        begin
          service.commit!(acknowledged_verification_items: ack_payload)
          outcomes_mutex.synchronize { outcomes[:first] = :committed }
        rescue PayPeriodLifecycleService::InvalidTransitionError => e
          outcomes_mutex.synchronize { outcomes[:first] = [ :invalid_transition, e.message ] }
        rescue StandardError => e
          outcomes_mutex.synchronize { outcomes[:first] = [ :unexpected, e.class.name, e.message ] }
        ensure
          first_lock_acquired << false if first_lock_acquired.empty?
        end
      end
    end

    expect(first_lock_acquired.pop(timeout: 5)).to be(true)

    second_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        second_attempting << conn.select_value("SELECT pg_backend_pid()").to_i
        begin
          PayPeriodLifecycleService.new(pay_period: PayPeriod.find(period.id), actor: User.find(admin_user.id))
            .commit!(acknowledged_verification_items: ack_payload)
          outcomes_mutex.synchronize { outcomes[:second] = :committed }
        rescue PayPeriodLifecycleService::InvalidTransitionError => e
          outcomes_mutex.synchronize { outcomes[:second] = [ :invalid_transition, e.message ] }
        rescue StandardError => e
          outcomes_mutex.synchronize { outcomes[:second] = [ :unexpected, e.class.name, e.message ] }
        end
      end
    end

    second_pid = second_attempting.pop(timeout: 5)
    expect(second_pid).to be_a(Integer)

    contended = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
    ActiveRecord::Base.connection_pool.with_connection do |conn|
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        wait_event_type = conn.select_value(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{second_pid.to_i}"
        )
        if wait_event_type == "Lock"
          contended = true
          break
        end
        sleep 0.02
      end
    end

    release_first << true
    first_thread.join(10)
    second_thread.join(10)

    expect(contended).to be(true)
    expect(outcomes[:first]).to eq(:committed)
    expect(outcomes[:second]).to eq([ :invalid_transition, "Can only commit an approved pay period" ])
    expect(period.reload.status).to eq("committed")
    expect(PayPeriodVerificationAcknowledgement.where(pay_period_id: period.id, employee_verification_item_id: verification_item.id).count).to eq(1)
  ensure
    # Keep non-transactional test DB clean without requiring superuser session_replication_role.
    if defined?(company) && company&.persisted?
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        conn.transaction(requires_new: true) do
          conn.execute("ALTER TABLE pay_period_verification_acknowledgements DISABLE TRIGGER pay_period_verification_acknowledgements_append_only")
          PayPeriodVerificationAcknowledgement.where(company_id: company.id).delete_all
          conn.execute("ALTER TABLE pay_period_verification_acknowledgements ENABLE TRIGGER pay_period_verification_acknowledgements_append_only")
        end
        conn.transaction(requires_new: true) do
          conn.execute("ALTER TABLE check_events DISABLE TRIGGER check_events_append_only")
          CheckEvent.where(company_id: company.id).delete_all
          conn.execute("ALTER TABLE check_events ENABLE TRIGGER check_events_append_only")
        end

        event_ids = PortalNotificationEvent.where(company_id: company.id).pluck(:id)
        PortalNotificationDelivery.where(portal_notification_event_id: event_ids).delete_all if event_ids.any?
        PortalNotificationEvent.where(id: event_ids).delete_all if event_ids.any?
        EmployeeVerificationItem.where(company_id: company.id).delete_all
        NonEmployeeCheck.where(company_id: company.id).find_each(&:destroy!)
        PayrollLiabilityEntry.where(company_id: company.id).delete_all if defined?(PayrollLiabilityEntry)
        PayrollLiabilityPosting.where(company_id: company.id).delete_all if defined?(PayrollLiabilityPosting)
        PayrollReviewPackage.where(company_id: company.id).delete_all if defined?(PayrollReviewPackage)
        item_ids = PayrollItem.where(company_id: company.id).pluck(:id)
        PayrollItemEarning.where(payroll_item_id: item_ids).delete_all if item_ids.any?
        PayrollItemDeduction.where(payroll_item_id: item_ids).delete_all if item_ids.any?
        PayrollItem.where(id: item_ids).delete_all if item_ids.any?
        EmployeeYtdTotal.where(employee_id: employee.id).delete_all if defined?(employee) && employee&.persisted?
        CompanyYtdTotal.where(company_id: company.id).delete_all
        EmployeeW4Election.where(company_id: company.id).delete_all
        EmployeeCompensationChange.where(company_id: company.id).delete_all
        PayPeriod.where(company_id: company.id).delete_all
        Employee.where(company_id: company.id).delete_all
        Department.where(company_id: company.id).delete_all
        ClientOperatingProfile.where(company_id: company.id).delete_all
        AuditLog.where(company_id: company.id).delete_all
        User.where(id: admin_user.id).delete_all if defined?(admin_user) && admin_user&.persisted?
        Company.where(id: company.id).delete_all
        Organization.where(id: organization.id).delete_all if defined?(organization) && organization&.persisted?
      end
    end
    verification_tables&.each(&:destroy!)
  end
end
