# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeIntakePolicy do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company) }
  let(:admin) { create(:user, company: company) }
  let(:manager) { create(:user, company: company, role: "manager") }
  let(:accountant) { create(:user, company: company, role: "accountant") }

  def enable_window
    company.update!(employee_intake_expires_at: 1.hour.from_now, employee_intake_reason: "Employer information outstanding", employee_intake_enabled_by_id: admin.id)
  end

  def incomplete_employee
    enable_window
    employee = build(:employee, company: company, ssn_encrypted: nil, hire_date: nil, address_line1: nil, city: nil, state: nil, zip: nil)
    described_class.prepare!(employee, actor: accountant)
    employee.save!
    employee
  end

  def confirm(employee, **options)
    EmployeeIntakeExceptionReviewService.call!(employee: employee, actor: manager, attributes: {
      confirm_payroll_setup: true, payroll_eligible_from: "2026-01-01", reason: "Confirmed actual pay setup with employer", acknowledge_default_withholding: true
    }.merge(options))
  end

  it "permits deferred business EIN while preserving its nonblank format" do
    enable_window
    employee = build(:employee, :business_contractor, company: company, contractor_ein: nil)
    described_class.prepare!(employee, actor: accountant)
    expect(employee).to be_valid
    employee.save!
    expect(employee.update(contractor_ein: "123")).to be false
  end

  it "uses one admission decision when the clock crosses the window expiration" do
    enable_window
    actor = accountant
    employee = build(:employee, company: company, w4_effective_on: nil)
    expiry = company.employee_intake_expires_at
    allow(Time).to receive(:current).and_return(expiry - 0.000001, expiry + 0.000001)
    described_class.prepare!(employee, actor: actor)
    expect(employee.intake_exception.fetch("deferred_fields")).to include("withholding_election")
  end

  it "keeps a blank encrypted identifier visible in the incomplete roster after other details are supplied" do
    enable_window
    employee = build(:employee, company: company, ssn_encrypted: "", w4_effective_on: "2026-01-01")
    described_class.prepare!(employee, actor: accountant)
    employee.save!
    EmployeeW4ElectionChangeService.new(employee: employee, actor: accountant,
      source: "employee_creation", reason: "Synthetic received election",
      attributes: { w4_effective_on: "2026-01-01" }).call!
    expect(described_class.summary(employee)[:missing_fields]).to eq([ "ssn" ])
    expect(company.employees.intake_incomplete).to include(employee)
  end

  it "keeps whitespace-only address details visible in the incomplete roster" do
    enable_window
    employee = build(:employee, company: company, city: "   ", w4_effective_on: "2026-01-01")
    described_class.prepare!(employee, actor: accountant)
    employee.save!
    EmployeeW4ElectionChangeService.new(employee: employee, actor: accountant,
      source: "employee_creation", reason: "Synthetic received election",
      attributes: { w4_effective_on: "2026-01-01" }).call!
    expect(employee.reload.city).to be_nil
    expect(described_class.summary(employee)[:missing_fields]).to eq([ "city" ])
    expect(company.employees.intake_incomplete).to include(employee)
  end

  it "prints a check without an address while retaining W-2GU blockers" do
    require "pdf/reader"
    employee = incomplete_employee
    period = create(:pay_period, :committed, company: company, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-19")
    item = create(:payroll_item, :with_check, employee: employee, pay_period: period)
    text = PDF::Reader.new(StringIO.new(CheckGenerator.new(item).generate)).pages.map(&:text).join("\n")
    expect(text).to include(employee.full_name)
    expect(employee.full_address).to eq("")
    findings = W2GuPreflightValidator.new(company: company, year: 2026).run.fetch(:findings)
    expect(findings).to include(a_hash_including(code: "EMPLOYEE_SSN_MISSING"), a_hash_including(code: "EMPLOYEE_ADDRESS_INCOMPLETE"))
  end

  it "invalidates the current database confirmation despite a stale loaded wage employee" do
    employee = create(:employee, company: company)
    rate = employee.employee_wage_rates.create!(label: "Secondary", rate: 20)
    stale_employee = rate.employee
    Employee.where(id: employee.id).update_all(intake_exception: { "deferred_fields" => [ "ssn" ] }, intake_payroll_confirmed_at: Time.current)
    expect(stale_employee.intake_exception).to be_empty
    rate.send(:invalidate_intake_confirmation!)
    expect(employee.reload.intake_payroll_confirmed_at).to be_nil
    expect(rate.employee).not_to be_changed
    expect { rate.employee.with_lock { } }.not_to raise_error
  end

  it "lists a legacy individual contractor with NULL contractor type and missing SSN" do
    employee = create(:employee, :contractor, company: company)
    employee.update_columns(contractor_type: nil, ssn_encrypted: nil, intake_exception: { "deferred_fields" => [ "ssn" ] })
    expect(company.employees.intake_incomplete).to include(employee)
    expect(described_class.summary(employee.reload)[:missing_fields]).to include("ssn")
  end

  it "compares equivalent raw date formats without losing malformed input validation" do
    employee = create(:employee, company: company, hire_date: "2026-01-01")
    service = ClientEmployeeUpdateService.new(employee: employee, company: company, requested_by: accountant, attrs: { hire_date: "2026/01/01" })
    result = service.update!
    expect(result.changed_fields).to be_empty
    expect(employee.reload.hire_date).to eq(Date.new(2026, 1, 1))
    service = ClientEmployeeUpdateService.new(employee: employee, company: company, requested_by: accountant, attrs: { hire_date: "not a date" })
    expect { service.update! }.to raise_error(ActiveRecord::RecordInvalid, /valid date/)
  end

  it "defaults to strict intake and fails closed after expiration" do
    expect(described_class.enabled?(company)).to be false
    enable_window
    travel 2.hours do
      employee = build(:employee, company: company, ssn_encrypted: nil)
      described_class.prepare!(employee, actor: accountant)
      expect(employee).not_to be_valid
      expect(employee.intake_exception).to be_empty
    end
  end

  it "records authorized missing fields and a follow-up owner without changing classification" do
    employee = incomplete_employee
    expect(employee.intake_exception).to include("created_by_id" => accountant.id, "authorized_by_id" => admin.id)
    expect(described_class.summary(employee)).to include(profile_incomplete: true, missing_fields: match_array(%w[ssn hire_date address_line1 city state zip withholding_election]))
    expect(employee.tax_classification).to eq("w2")
  end

  it "permits incremental completion after restoration but rejects clearing completed fields" do
    employee = incomplete_employee
    company.update!(employee_intake_expires_at: nil)
    employee.update!(address_line1: "123 Main Street")
    employee.update!(city: "Hagatna")
    expect(employee.update(address_line1: nil)).to be false
    expect(employee.errors[:address_line1]).to include("can't be blank")
    expect(described_class.summary(employee.reload)[:missing_fields]).not_to include("address_line1", "city")
  end

  it "validates supplied identifiers and confirmation despite relaxed presence requirements" do
    employee = incomplete_employee
    employee.require_ssn_confirmation = true
    expect(employee.update(ssn_encrypted: "123", ssn_confirmation: "123")).to be false
    employee.reload
    expect(employee.update(ssn_encrypted: "900-70-1234", ssn_confirmation: "900-70-1235")).to be false
    employee.reload
    expect(employee.update(ssn_encrypted: "900-70-1234", ssn_confirmation: "900-70-1234")).to be true
  end

  it "rejects invalid supplied dates" do
    employee = incomplete_employee
    expect(employee.update(hire_date: "nonsense")).to be false
    expect(employee.errors[:hire_date]).to be_present
  end

  it "never invents an initial election without an explicit date" do
    employee = incomplete_employee
    EmployeeW4ElectionChangeService.new(employee: employee, actor: accountant, source: "employee_creation", reason: nil,
      attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attr| employee.public_send(attr) }).call!
    expect(employee.employee_w4_elections).to be_empty
  end

  it "excludes unknown eligibility until manager confirmation, then limits payroll dates" do
    employee = incomplete_employee
    expect(company.employees.eligible_for_period(Date.new(2026, 1, 1), Date.new(2026, 1, 14))).not_to exist
    expect(employee.eligible_on?(Date.new(2026, 1, 1))).to be false
    confirm(employee)
    expect(company.employees.eligible_for_period(Date.new(2026, 1, 1), Date.new(2026, 1, 14))).to exist
    expect(employee.eligible_on?(Date.new(2025, 12, 31))).to be false
    expect(employee.eligible_on?(Date.new(2026, 1, 1))).to be true
    expect(employee.employee_w4_elections.first).to have_attributes(source: "default_withholding", filing_status: "single", w4_signed_on: nil)
    expect(described_class.summary(employee)[:missing_fields]).to include("withholding_election")
  end

  it "requires affirmative default acknowledgement and a reason" do
    employee = incomplete_employee
    expect { confirm(employee, acknowledge_default_withholding: false) }.to raise_error(EmployeeIntakeExceptionReviewService::Error, /acknowledge/)
    expect { confirm(employee, reason: "") }.to raise_error(EmployeeIntakeExceptionReviewService::Error, /Explain/)
    expect(employee.reload.intake_payroll_confirmed_at).to be_nil
  end

  it "blocks accountants from confirming payroll setup" do
    employee = incomplete_employee
    expect { EmployeeIntakeExceptionReviewService.call!(employee: employee, actor: accountant, attributes: { confirm_payroll_setup: true }) }.to raise_error(EmployeeIntakeExceptionReviewService::Error, /Manager/)
  end

  it "invalidates confirmation after changing compensation" do
    employee = incomplete_employee
    confirm(employee)
    employee.update!(pay_rate: 20)
    expect(employee.reload.intake_payroll_confirmed_at).to be_nil
  end

  it "preserves confirmation for ordinary address completion" do
    employee = incomplete_employee
    confirm(employee)
    employee.update!(city: "Hagatna")
    expect(employee.reload.intake_payroll_confirmed_at).to be_present
  end

  it "records a real election separately from the acknowledged default" do
    employee = incomplete_employee
    confirm(employee)
    EmployeeW4ElectionChangeService.new(employee: employee, actor: manager, source: "staff", reason: "Signed form received", election_received: true,
      attributes: { w4_effective_on: "2026-01-01", w4_source_reference: "Signed employee W-4 document" }).call!
    expect(employee.employee_w4_elections.count).to eq(2)
    expect(described_class.summary(employee)[:missing_fields]).not_to include("withholding_election")
  end

  it "requires payroll confirmation, current calculation, and independently reviewed documents" do
    employee = incomplete_employee
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: accountant)
    period = create(:pay_period, company: company, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-19")
    item = create(:payroll_item, employee: employee, pay_period: period)
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.to raise_error(EmployeeDocumentReadiness::BlockedError, /Confirm payroll setup/)
    confirm(employee)
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.to raise_error(EmployeeDocumentReadiness::BlockedError, /Recalculate/)
    item.update!(calculation_context_snapshot: { "intake_setup_fingerprint" => PayrollCalculationContext.intake_setup_fingerprint(employee: employee) }, tax_rule_snapshot: { "w4" => { "election_id" => employee.employee_w4_elections.first.id } })
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.to raise_error(EmployeeDocumentReadiness::BlockedError, /new-hire documents/)
    employee.employee_document_requirements.each do |requirement|
      EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: manager,
        attributes: { status: "waived", review_note: "Manager reviewed missing document exception", lock_version: requirement.lock_version }).call!
    end
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.not_to raise_error
  end

  it "preserves received-election intent and evidence through client approval" do
    employee = incomplete_employee
    confirm(employee)
    profile = EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
    result = ClientEmployeeUpdateService.new(employee: employee, company: company, requested_by: accountant,
      attrs: profile.merge(w4_election_received: true, w4_source_reference: "Signed employee W-4 uploaded")).update!
    result.change_request.apply!(actor: manager)
    expect(employee.reload.employee_w4_elections.count).to eq(2)
    expect(employee.employee_w4_elections.recent_first.first.source).to eq("client_approved")
  end

  it "rejects client withholding changes without received-election intent before queuing approval" do
    employee = incomplete_employee
    confirm(employee)
    service = ClientEmployeeUpdateService.new(employee: employee, company: company, requested_by: accountant,
      attrs: { filing_status: "married" })
    expect { service.update! }.to raise_error(ActiveRecord::RecordInvalid, /record receipt/)
    expect(employee.employee_change_requests).to be_empty
  end

  it "blocks stale compensation even after manager reconfirmation" do
    create(:tax_table, tax_year: 2026)
    employee = incomplete_employee
    employee.update!(pay_rate: 20)
    confirm(employee)
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: accountant)
    employee.employee_document_requirements.each do |requirement|
      EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: manager,
        attributes: { status: "waived", review_note: "Manager reviewed outstanding document", lock_version: requirement.lock_version }).call!
    end
    period = create(:pay_period, company: company, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-19")
    item = create(:payroll_item, employee: employee, pay_period: period, pay_rate: 20)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.not_to raise_error
    employee.update!(pay_rate: 30)
    confirm(employee)
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.to raise_error(EmployeeDocumentReadiness::BlockedError, /Recalculate/)
    item.update!(pay_rate: 30)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.not_to raise_error
  end

  it "invalidates setup when the sync service changes a secondary wage" do
    employee = incomplete_employee
    primary = employee.employee_wage_rates.create!(label: "Primary", rate: 20, is_primary: true)
    secondary = employee.employee_wage_rates.create!(label: "Secondary", rate: 25, is_primary: false)
    confirm(employee)
    fingerprint = PayrollCalculationContext.intake_setup_fingerprint(employee: employee)
    EmployeeWageRateSyncService.new(employee: employee, wage_rates: [
      { id: primary.id, label: "Primary", rate: 20, is_primary: true },
      { id: secondary.id, label: "Secondary", rate: 30, is_primary: false }
    ]).sync!
    expect(employee.reload.intake_payroll_confirmed_at).to be_nil
    expect(PayrollCalculationContext.intake_setup_fingerprint(employee: employee)).not_to eq(fingerprint)
  end

  def calculated_intake_payroll
    create(:tax_table, tax_year: 2026)
    employee = incomplete_employee
    yield employee if block_given?
    confirm(employee)
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: accountant)
    employee.employee_document_requirements.each do |requirement|
      EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: manager,
        attributes: { status: "waived", review_note: "Synthetic reviewed document exception", lock_version: requirement.lock_version }).call!
    end
    period = create(:pay_period, company: company, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-19")
    item = create(:payroll_item, employee: employee, pay_period: period, pay_rate: employee.pay_rate)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.not_to raise_error
    [ employee, period, item ]
  end

  it "blocks a calculated deduction after its assignment is disabled" do
    assignment = nil
    _employee, period, _item = calculated_intake_payroll do |employee|
      type = DeductionType.create!(company: company, name: "Synthetic deduction", category: "post_tax", active: true)
      assignment = employee.employee_deductions.create!(deduction_type: type, amount: 25, active: true)
    end
    assignment.update!(active: false)
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.to raise_error(EmployeeDocumentReadiness::BlockedError, /Recalculate/)
  end

  it "blocks a calculated payroll field after its assignment is disabled" do
    assignment = nil
    _employee, period, _item = calculated_intake_payroll do |employee|
      field = create(:payroll_field_definition, company: company, kind: "deduction", tax_treatment: "post_tax_deduction")
      assignment = employee.employee_payroll_fields.create!(payroll_field_definition: field, amount: 25, active: true)
    end
    assignment.update!(active: false)
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.to raise_error(EmployeeDocumentReadiness::BlockedError, /Recalculate/)
  end

  it "requires recalculation after the earliest participation date is changed within the period" do
    employee, period, _item = calculated_intake_payroll
    confirm(employee, payroll_eligible_from: "2026-01-07")
    expect { EmployeeDocumentReadiness.require_payroll_ready!(period) }.to raise_error(EmployeeDocumentReadiness::BlockedError, /Recalculate/)
  end

  it "does not allow accountants to waive or regress reviewed document outcomes" do
    employee = incomplete_employee
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: accountant)
    requirement = employee.employee_document_requirements.first
    expect { EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: accountant,
      attributes: { status: "waived", review_note: "Employer information outstanding", lock_version: requirement.lock_version }).call! }.to raise_error(EmployeeDocumentRequirementReviewService::Error, /Manager/)
    EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: manager,
      attributes: { status: "waived", review_note: "Employer information outstanding", lock_version: requirement.lock_version }).call!
    expect { EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: accountant,
      attributes: { status: "received", lock_version: requirement.lock_version }).call! }.to raise_error(EmployeeDocumentRequirementReviewService::Error, /reviewed outcome/)
  end

  it "protects completed fields during client validation and rejects malformed dates" do
    employee = incomplete_employee
    employee.update!(city: "Hagatna")
    service = ClientEmployeeUpdateService.new(employee: employee, company: company, requested_by: accountant, attrs: { city: "" })
    expect { service.update! }.to raise_error(ActiveRecord::RecordInvalid)
    service = ClientEmployeeUpdateService.new(employee: employee.reload, company: company, requested_by: accountant, attrs: { hire_date: "nonsense" })
    expect { service.update! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "applies intake exceptions and document requirements to new client entries and approval" do
    enable_window
    result = ClientEmployeeUpdateService.new(employee: Employee.new, company: company, requested_by: accountant,
      attrs: { first_name: "Alex", last_name: "Worker", employment_type: "hourly", pay_rate: 20, pay_frequency: "biweekly" }).create!
    expect(result.employee).to be_portal_pending_approval
    expect(result.employee.intake_exception).to be_present
    expect(result.employee.employee_document_requirements.count).to eq(2)
    company.update!(employee_intake_expires_at: nil)
    result.change_request.apply!(actor: manager)
    expect(result.employee.reload).to be_active
    expect(result.employee.employee_w4_elections).to be_empty
  end

  it "revalidates imports after expiration and seeds the checklist on successful intake" do
    enable_window
    service = EmployeeBulkImport::ImportService.new(company, actor: accountant)
    minimal = { "first_name" => "Alex", "last_name" => "Worker", "employment_type" => "hourly", "pay_rate" => "20", "pay_frequency" => "biweekly" }
    expect(service.send(:validate_row_data, minimal)).to be_empty
    attrs = service.send(:build_attributes, minimal, {})
    rows = [ { row_number: 2, attributes: attrs } ]
    company.update!(employee_intake_expires_at: nil)
    expect(service.create_employees!(rows)).to include(created: 0, failed: 1)
    enable_window
    expect(service.create_employees!(rows)).to include(created: 1, failed: 0)
    expect(company.employees.last.employee_document_requirements.count).to eq(2)
    expect(company.employees.last.employee_w4_elections).to be_empty
  end
end
