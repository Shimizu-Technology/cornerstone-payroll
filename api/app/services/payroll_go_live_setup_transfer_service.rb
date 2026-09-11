# frozen_string_literal: true

class PayrollGoLiveSetupTransferService
  ACKNOWLEDGEMENT = "COPY REVIEWED LIVE SETUP"
  EMPLOYEE_FIELDS = %w[
    date_of_birth hire_date job_title pay_frequency pay_rate salary_type status
    retirement_rate roth_retirement_rate employer_retirement_match_rate employer_roth_match_rate
    default_custom_earnings default_payroll_adjustments address_line1 address_line2 city state zip phone email
    contractor_type contractor_pay_type business_name contractor_ein w9_on_file
    ssn_encrypted bank_routing_number_encrypted bank_account_number_encrypted
  ].freeze
  DEDUCTION_TYPE_FIELDS = %w[
    name category sub_category default_amount is_percentage active generates_check payee_name reference_number reporting_group
  ].freeze
  PAYROLL_FIELD_FIELDS = %w[
    name description kind tax_treatment category amount_type default_amount default_percentage
    show_in_payroll_grid sort_order active payee_name reference_number reporting_group
  ].freeze

  def self.preview!(company:, source_company:, batch:, effective_on:, actor:)
    authorize_preview!(actor, company, source_company)
    plan = PayrollGoLiveSetupPlan.new(company:, source_company:, batch:, effective_on:).call
    review = company.payroll_go_live_review || company.build_payroll_go_live_review(created_by: actor)
    raise ArgumentError, "Approved go-live evidence is sealed" if review.approved?
    raise ArgumentError, "The reviewed setup has already been applied; its source and transfer date are now fixed" if review.setup_applied?

    review.assign_attributes(
      source_company: source_company,
      historical_import_batch: batch,
      effective_on: effective_on,
      status: "draft",
      plan_digest: plan.digest,
      setup_summary: plan.summary,
      setup_plan: plan.plan,
      warnings: plan.warnings,
      validation_errors: plan.errors
    )
    review.save!
    audit!(review, actor, "payroll_go_live#preview_setup", ready: plan.ready?)
    review
  end

  def self.apply!(review:, actor:, acknowledgement:)
    authorize_apply!(actor, review)
    raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
    return review if review.setup_applied?

    PayrollGoLiveReview.transaction do
      review.source_company.lock!
      review.company.lock!
      review.lock!
      next review if review.setup_applied?

      plan = PayrollGoLiveSetupPlan.new(
        company: review.company,
        source_company: review.source_company,
        batch: review.historical_import_batch,
        effective_on: review.effective_on
      ).call
      raise ArgumentError, plan.errors.join("; ") unless plan.ready?
      unless ActiveSupport::SecurityUtils.secure_compare(plan.digest, review.plan_digest)
        raise ArgumentError, "Source or successor setup changed. Build and review a new preview."
      end

      definition_map = copy_payroll_field_definitions!(review)
      deduction_type_map = copy_deduction_types!(review)
      department_map = copy_departments!(review)
      copy_company_settings!(review)
      copy_schedule!(review, actor)
      plan.employee_matches.each do |source, target|
        copy_employee!(source, target, review, actor, department_map, deduction_type_map, definition_map)
      end

      review.update!(status: "setup_applied", setup_applied_at: Time.current, setup_applied_by: actor)
      audit!(review, actor, "payroll_go_live#apply_setup", employee_count: plan.employee_matches.size)
      review
    end
  end

  def self.authorize_preview!(actor, company, source_company)
    allowed = actor&.payroll_access_allowed? && actor.can_access_company?(company.id) &&
      actor.can_access_company?(source_company.id) && StaffRolePolicy.allowed?(actor, :manage_client_configuration)
    raise ArgumentError, "A manager or administrator with access to both clients is required" unless allowed
  end

  def self.authorize_apply!(actor, review)
    allowed = actor&.payroll_access_allowed? && actor.can_access_company?(review.company_id) &&
      actor.can_access_company?(review.source_company_id) && StaffRolePolicy.allowed?(actor, :manage_platform)
    raise ArgumentError, "A super administrator must apply setup containing protected employee data" unless allowed
  end

  def self.copy_company_settings!(review)
    attributes = review.source_company.attributes.slice(*PayrollGoLiveSetupPlan::COMPANY_FIELDS)
    attributes["check_layout_config"] = CheckLayoutConfigSanitizer.call(
      stock_type: attributes.fetch("check_stock_type"),
      config: attributes.fetch("check_layout_config")
    )
    review.company.update!(attributes)
  end

  def self.copy_schedule!(review, actor)
    source_schedule = CompanyPaySchedule.for_date(review.source_company_id, review.effective_on)
    source_workweek = CompanyWorkweek.for_date(review.source_company_id, review.effective_on)
    CompanyPayScheduleChangeService.call!(
      company: review.company,
      actor: actor,
      effective_on: review.effective_on,
      schedule_attributes: source_schedule.attributes.symbolize_keys.slice(
        :frequency, :period_rule, :period_start_weekday, :period_anchor_date,
        :pay_date_rule, :pay_date_offset_days, :timezone
      ).merge(notes: "Confirmed from reviewed predecessor client #{review.source_company.name}"),
      workweek_attributes: source_workweek.attributes.symbolize_keys.slice(
        :starts_on_weekday, :starts_at_minutes, :timezone
      ).merge(notes: "Confirmed from reviewed predecessor client #{review.source_company.name}")
    )
  end

  def self.copy_departments!(review)
    review.source_company.departments.index_with do |source|
      review.company.departments.find_or_initialize_by(name: source.name).tap do |target|
        target.update!(active: source.active)
      end
    end
  end

  def self.copy_deduction_types!(review)
    review.source_company.deduction_types.index_with do |source|
      review.company.deduction_types.find_or_initialize_by(name: source.name).tap do |target|
        next if target.persisted? && review.company.employee_loans.exists?(deduction_type_id: target.id)

        target.update!(source.attributes.slice(*DEDUCTION_TYPE_FIELDS))
      end
    end
  end

  def self.copy_payroll_field_definitions!(review)
    review.source_company.payroll_field_definitions.index_with do |source|
      review.company.payroll_field_definitions.find_or_initialize_by(name: source.name).tap do |target|
        next if target.persisted? && target.employee_payroll_fields.where.not(employee_loan_id: nil).exists?

        target.update!(source.attributes.slice(*PAYROLL_FIELD_FIELDS))
      end
    end
  end

  def self.copy_employee!(source, target, review, actor, department_map, deduction_type_map, definition_map)
    attributes = source.attributes.slice(*EMPLOYEE_FIELDS)
    held_loan_adjustments = false
    attributes["default_payroll_adjustments"] = Employee.normalize_payroll_adjustments(source.default_payroll_adjustments).map do |adjustment|
      if adjustment["active"] != false && adjustment["treatment"] == "post_tax_deduction" && adjustment["label"].match?(/\bloan\b/i)
        held_loan_adjustments = true
        adjustment.merge("active" => false)
      else
        adjustment
      end
    end
    target.update!(attributes.merge(department: source.department && department_map.fetch(source.department)))
    flag_loan_reconciliation!(target) if held_loan_adjustments
    copy_w4!(source, target, review, actor)
    copy_wage_rates!(source, target)
    copy_deductions!(source, target, deduction_type_map)
    copy_payroll_fields!(source, target, definition_map)
    copy_work_profile!(source, target, review, actor)
  end

  def self.copy_w4!(source, target, review, actor)
    return if target.contractor?

    election = source.w4_election_on(review.effective_on) || source.employee_w4_elections.recent_first.first
    return unless election

    EmployeeW4ElectionChangeService.new(
      employee: target,
      attributes: election.profile_attributes.merge(w4_effective_on: review.effective_on),
      actor: actor,
      source: "staff",
      reason: "Reviewed successor setup copied from #{review.source_company.name}"
    ).call!
  end

  def self.copy_wage_rates!(source, target)
    source.employee_wage_rates.each do |source_rate|
      target.employee_wage_rates.find_or_initialize_by(label: source_rate.label).update!(
        rate: source_rate.rate,
        active: source_rate.active,
        is_primary: source_rate.is_primary
      )
    end
  end

  def self.copy_deductions!(source, target, type_map)
    source.employee_deductions.each do |source_deduction|
      deduction_type = type_map.fetch(source_deduction.deduction_type)
      tracked = source.employee_loans.exists?(deduction_type_id: source_deduction.deduction_type_id)
      if target.employee_loans.exists?(deduction_type_id: deduction_type.id)
        flag_loan_reconciliation!(target)
        next
      end
      target.employee_deductions.find_or_initialize_by(deduction_type: deduction_type).update!(
        amount: source_deduction.amount,
        is_percentage: source_deduction.is_percentage,
        active: tracked ? false : source_deduction.active
      )
      flag_loan_reconciliation!(target) if tracked
    end
  end

  def self.copy_payroll_fields!(source, target, definition_map)
    source.employee_payroll_fields.each do |source_field|
      definition = definition_map.fetch(source_field.payroll_field_definition)
      target_field = target.employee_payroll_fields.find_or_initialize_by(payroll_field_definition: definition)
      if target_field.employee_loan_id.present?
        flag_loan_reconciliation!(target)
        next
      end
      tracked = source_field.employee_loan_id.present?
      target_field.update!(
        amount: source_field.amount,
        percentage: source_field.percentage,
        active: tracked ? false : source_field.active,
        start_date: source_field.start_date,
        end_date: source_field.end_date,
        notes: "Copied from reviewed predecessor setup; verify before first live payroll",
        employee_loan: nil
      )
      flag_loan_reconciliation!(target) if tracked
    end
  end

  def self.flag_loan_reconciliation!(target)
    code = "loan_balance_not_transferred"
    items = target.configuration_review_items.reject { |item| item["code"] == code }
    items << {
      "code" => code,
      "message" => "A transferred loan deduction requires a verified successor obligation and repayment schedule. Copied loan deductions are inactive; existing successor loan schedules were retained. Reconcile in Employee Loans before payroll.",
      "fields" => []
    }
    target.update!(configuration_review_status: "needs_review", configuration_review_items: items)
  end

  def self.copy_work_profile!(source, target, review, actor)
    profile = EmployeeWorkProfile.for_date(source.id, review.effective_on)
    return unless profile

    EmployeeWorkProfileChangeService.call!(
      employee: target,
      actor: actor,
      attributes: profile.attributes.symbolize_keys.slice(
        :pay_basis, :overtime_status, :exemption_category, :exemption_reason,
        :standard_weekly_hours, :salary_covers_weekly_hours, :salary_coverage_reason,
        :timekeeping_mode, :daily_schedule
      ).merge(
        effective_on: review.effective_on.iso8601,
        source: "production_migration",
        notes: "Confirmed from reviewed predecessor client #{review.source_company.name}"
      )
    )
  end

  def self.audit!(review, actor, action, metadata = {})
    AuditLog.record!(
      user: actor,
      organization_id: review.company.organization_id,
      company_id: review.company_id,
      action: action,
      record_type: "payroll_go_live_reviews",
      record_id: review.id,
      subject_name: review.company.name,
      metadata: metadata.merge(source_company_id: review.source_company_id, plan_digest: review.plan_digest)
    )
  end

  private_class_method :authorize_preview!, :authorize_apply!, :copy_company_settings!, :copy_schedule!,
    :copy_departments!, :copy_deduction_types!, :copy_payroll_field_definitions!, :copy_employee!,
    :copy_w4!, :copy_wage_rates!, :copy_deductions!, :copy_payroll_fields!, :copy_work_profile!, :audit!
end
