# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Unified check printing workflow" do
  let(:company) { create(:company, check_stock_type: "first_hawaiian_4up") }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:printer_profile) do
    PrinterProfile.create!(organization: company.organization, name: "Payroll Room Printer",
      check_stock_type: company.check_stock_type, check_offset_x: 0.125, check_offset_y: -0.025)
  end
  let(:employee) { create(:employee, company: company) }
  let!(:employee_check) do
    create(:payroll_item, :with_check,
      company: company,
      pay_period: pay_period,
      employee: employee,
      check_number: "1002",
      net_pay: 960)
  end
  let!(:non_employee_check) do
    create(:non_employee_check,
      company: company,
      pay_period: pay_period,
      payment_period_type: "pay_period",
      tax_year: nil,
      tax_month: nil,
      check_number: "1001",
      amount: 125.50)
  end
  let(:stored) { {} }
  let(:storage) do
    instance_double(R2StorageService).tap do |service|
      allow(service).to receive(:upload) { |key, io, **| stored[key] = io.read }
      allow(service).to receive(:delete) { |key| stored.delete(key) }
    end
  end

  it "builds one mixed queue in check-number order" do
    UserPrinterProfileSelection.create!(user: actor, organization: company.organization,
      check_stock_type: company.check_stock_type, printer_profile: printer_profile)
    result = CheckPrintQueueService.new(pay_period: pay_period, actor: actor).call

    expect(result.fetch(:items).map { |item| item.fetch(:key) }).to eq([
      "non_employee_check:#{non_employee_check.id}",
      "payroll_item:#{employee_check.id}"
    ])
    expect(result.dig(:meta, :unprinted)).to eq(2)
    expect(result.dig(:meta, :check_stock_type)).to eq("first_hawaiian_4up")
    expect(result.dig(:meta, :printer_profile, :id)).to eq(printer_profile.id)
  end

  it "keeps an older unnumbered non-employee check visible but ineligible" do
    pending_check = create(:non_employee_check,
      company: company,
      pay_period: pay_period,
      payment_period_type: "pay_period",
      tax_year: nil,
      tax_month: nil,
      check_number: nil,
      payable_to: "Treasurer of Guam",
      amount: 43.13)

    result = CheckPrintQueueService.new(pay_period: pay_period).call
    item = result.fetch(:items).find { |entry| entry.fetch(:key) == "non_employee_check:#{pending_check.id}" }

    expect(item).to include(
      check_number: "",
      status: "pending",
      eligible: false,
      disabled_reason: "Assign a check number before printing"
    )
  end

  it "persists the exact mixed package and marks records only after confirmation" do
    run = CheckPrintRunGenerationService.new(
      pay_period: pay_period,
      actor: actor,
      payroll_item_ids: [ employee_check.id ],
      non_employee_check_ids: [ non_employee_check.id ],
      starting_slot: 3,
      printer_profile_id: printer_profile.id,
      printer_profile_lock_version: printer_profile.lock_version,
      storage: storage
    ).call

    expect(run.status).to eq("generated")
    expect(run.manifest.map { |entry| entry.fetch("check_number") }).to eq(%w[1001 1002])
    expect(run).to have_attributes(starting_slot: 3, selected_count: 2)
    expect(run).to have_attributes(printer_profile_id: printer_profile.id)
    expect(run.calibration_snapshot).to include(
      "printer_profile_name" => "Payroll Room Printer",
      "printer_profile_lock_version" => printer_profile.lock_version,
      "check_offset_x" => "0.125"
    )
    expect(stored.fetch(run.storage_key)).to start_with("%PDF")
    expect(employee_check.reload.check_printed_at).to be_nil
    expect(non_employee_check.reload.printed_at).to be_nil

    result = CheckPrintRunConfirmationService.new(run: run, actor: actor).call

    expect(result.fetch(:marked_printed)).to eq(2)
    expect(run.reload).to be_confirmed
    expect(employee_check.reload).to have_attributes(check_print_count: 1)
    expect(employee_check.check_printed_at).to be_present
    expect(non_employee_check.reload).to have_attributes(print_count: 1)
    expect(non_employee_check.printed_at).to be_present

    repeated = CheckPrintRunConfirmationService.new(run: run, actor: actor).call
    expect(repeated).to include(already_confirmed: true, marked_printed: 0)
    expect(employee_check.reload.check_print_count).to eq(1)
    expect(non_employee_check.reload.print_count).to eq(1)
  end

  it "uses a unique download filename for every generated package" do
    first_run = CheckPrintRunGenerationService.new(
      pay_period: pay_period,
      actor: actor,
      payroll_item_ids: [ employee_check.id ],
      non_employee_check_ids: [],
      starting_slot: 1,
      printer_profile_id: printer_profile.id,
      printer_profile_lock_version: printer_profile.lock_version,
      storage: storage
    ).call
    second_run = CheckPrintRunGenerationService.new(
      pay_period: pay_period,
      actor: actor,
      payroll_item_ids: [ employee_check.id ],
      non_employee_check_ids: [],
      starting_slot: 1,
      printer_profile_id: printer_profile.id,
      printer_profile_lock_version: printer_profile.lock_version,
      storage: storage
    ).call

    expect(first_run.filename).to match(/\Acheck_run_\d{4}-\d{2}-\d{2}_[0-9a-f-]{36}\.pdf\z/)
    expect(second_run.filename).not_to eq(first_run.filename)
    expect(second_run.storage_key).not_to eq(first_run.storage_key)
  end

  it "rejects confirmation if a selected check changes after generation" do
    run = CheckPrintRunGenerationService.new(
      pay_period: pay_period,
      actor: actor,
      payroll_item_ids: [ employee_check.id ],
      non_employee_check_ids: [],
      starting_slot: 1,
      printer_profile_id: printer_profile.id,
      printer_profile_lock_version: printer_profile.lock_version,
      storage: storage
    ).call
    employee_check.update!(check_number: "1999")

    expect {
      CheckPrintRunConfirmationService.new(run: run, actor: actor).call
    }.to raise_error(CheckPrintRunConfirmationService::StaleSelectionError, /different check number/)

    expect(run.reload.status).to eq("generated")
    expect(employee_check.reload.check_printed_at).to be_nil
  end

  it "rejects a package when the reviewed printer calibration changed" do
    reviewed_version = printer_profile.lock_version
    printer_profile.update!(check_offset_x: 0.25)

    expect {
      CheckPrintRunGenerationService.new(
        pay_period: pay_period,
        actor: actor,
        payroll_item_ids: [ employee_check.id ],
        non_employee_check_ids: [],
        starting_slot: 1,
        printer_profile_id: printer_profile.id,
        printer_profile_lock_version: reviewed_version,
        storage: storage
      ).call
    }.to raise_error(CheckRenderSettings::StaleProfileError, /changed after you opened/)

    expect(CheckPrintRun.where(pay_period: pay_period)).to be_empty
    expect(stored).to be_empty
  end

  it "optionally requires a different operator to confirm the print package" do
    company.update!(require_distinct_check_print_confirmer: true)
    confirmer = create(:user, company:, organization: company.organization)
    run = CheckPrintRunGenerationService.new(
      pay_period: pay_period,
      actor: actor,
      payroll_item_ids: [ employee_check.id ],
      non_employee_check_ids: [],
      starting_slot: 1,
      printer_profile_id: printer_profile.id,
      printer_profile_lock_version: printer_profile.lock_version,
      storage: storage
    ).call

    expect {
      CheckPrintRunConfirmationService.new(run:, actor: actor).call
    }.to raise_error(ArgumentError, /different authorized payroll operator/)
    expect(run.reload.status).to eq("generated")

    expect(CheckPrintRunConfirmationService.new(run:, actor: confirmer).call.fetch(:marked_printed)).to eq(1)
    expect(run.reload).to have_attributes(status: "confirmed", confirmed_by_id: confirmer.id)
  end
end
