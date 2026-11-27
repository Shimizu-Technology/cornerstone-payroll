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
      expect(new_hire.employee_document_requirements.pluck(:required_for_payroll)).to all(be(false))

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
    end
  end
end
