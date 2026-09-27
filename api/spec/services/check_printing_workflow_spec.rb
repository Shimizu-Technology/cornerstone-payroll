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
      allow(service).to receive(:download) { |key| stored[key] }
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

  it "prepares selected checks when the exact mixed package is saved" do
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

    expect(run.status).to eq("prepared")
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
    expect(employee_check.check_prepared_at).to be_present
    expect(non_employee_check.prepared_at).to be_present
    expect(employee_check.check_print_count).to eq(0)
    expect(non_employee_check.print_count).to eq(0)
    expect(employee_check.check_events.where(event_type: "prepared").count).to eq(1)
    expect(employee_check.check_events.where(event_type: "printed")).to be_empty

    prepared_queue = CheckPrintQueueService.new(pay_period: pay_period, actor: actor).call
    expect(prepared_queue.dig(:meta, :total)).to eq(2)
    expect(prepared_queue.dig(:meta, :prepared)).to eq(2)
    expect(prepared_queue.fetch(:items)).to all(include(status: "prepared", eligible: true))

    second_run = CheckPrintRunGenerationService.new(
      pay_period: pay_period,
      actor: actor,
      payroll_item_ids: [ employee_check.id ],
      non_employee_check_ids: [ non_employee_check.id ],
      starting_slot: 1,
      printer_profile_id: printer_profile.id,
      printer_profile_lock_version: printer_profile.lock_version,
      storage: storage
    ).call
    expect(second_run).to have_attributes(status: "prepared", selected_count: 2)
    expect(employee_check.reload.check_print_count).to eq(0)
    expect(non_employee_check.reload.print_count).to eq(0)
    expect(employee_check.check_events.where(event_type: "prepared").count).to eq(1)

    employee_check.mark_delivered!(user: actor, delivered_on: PayrollBusinessClock.today,
      delivery_method: "hand_delivery", attestation: true)
    non_employee_check.mark_paid!(actor: actor, payment_date: PayrollBusinessClock.today)
    expect(CheckReconciliationStatus.for(employee_check.reload)).to eq("issued")
    expect(CheckReconciliationStatus.for(non_employee_check.reload)).to eq("issued")
    non_employee_check.void!(reason: "Payment was returned before clearing")
    expect(non_employee_check.reload).to be_voided
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

  it "requires a new package if a prepared check changes" do
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
    expect(CheckPrintRunHistoryVerifier.new(runs: [ run ]).call.fetch(run.id).first).to eq("prepared")
    employee_check.update!(check_number: "1999")

    expect(run.reload.status).to eq("prepared")
    expect(CheckPrintRunHistoryVerifier.new(runs: [ run ]).call.fetch(run.id).first).to eq("outdated")
    expect(employee_check.reload.check_prepared?).to be(false)
    expect {
      employee_check.mark_delivered!(user: actor, delivered_on: PayrollBusinessClock.today,
        delivery_method: "hand_delivery", attestation: true)
    }.to raise_error(ArgumentError, /Generate a current check package/)
  end

  it "blocks issuance when the employee name on a prepared check changes" do
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
    expect(employee_check.reload.check_prepared?).to be(true)

    employee.update!(first_name: "Changed")
    expect(CheckPrintRunHistoryVerifier.new(runs: [ run ]).call.fetch(run.id).first).to eq("outdated")

    expect {
      employee_check.reload.mark_delivered!(user: actor, delivered_on: PayrollBusinessClock.today,
        delivery_method: "hand_delivery", attestation: true)
    }.to raise_error(ArgumentError, /Generate a current check package/)
  end

  it "keeps a saved package current after separate physical print tracking" do
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

    employee_check.mark_printed!(user: actor)

    expect(employee_check.reload.check_print_count).to eq(1)
    expect(CheckPrintRunHistoryVerifier.new(runs: [ run ]).call.fetch(run.id).first).to eq("prepared")
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

  it "does not prepare checks when the saved artifact fails verification" do
    allow(storage).to receive(:download).and_return("corrupt bytes")

    expect {
      CheckPrintRunGenerationService.new(
        pay_period: pay_period,
        actor: actor,
        payroll_item_ids: [ employee_check.id ],
        non_employee_check_ids: [ non_employee_check.id ],
        starting_slot: 1,
        printer_profile_id: printer_profile.id,
        printer_profile_lock_version: printer_profile.lock_version,
        storage: storage
      ).call
    }.to raise_error(R2StorageService::UploadError, /integrity check/)

    expect(CheckPrintRun.where(pay_period: pay_period)).to be_empty
    expect(employee_check.reload.check_prepared_at).to be_nil
    expect(non_employee_check.reload.prepared_at).to be_nil
  end

  it "keeps PDF parser details out of package assembly errors" do
    service = CheckPrintRunGenerationService.allocate
    allow(CombinePDF).to receive(:parse).and_raise(ArgumentError, "private xref parser detail")
    allow(Rails.logger).to receive(:error)

    expect {
      service.send(:combine_pdfs, [ "first", "second" ])
    }.to raise_error(
      CheckPrintRunGenerationService::PdfAssemblyError,
      "The package PDF could not be assembled"
    )
    expect(Rails.logger).to have_received(:error).with(include("ArgumentError: private xref parser detail"))
  end
end
