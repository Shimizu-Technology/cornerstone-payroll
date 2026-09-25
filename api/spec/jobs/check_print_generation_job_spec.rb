# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckPrintGenerationJob do
  let(:company) { create(:company, check_stock_type: "top_check") }
  let(:user) { create(:user, company:, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company:) }
  let(:employee) { create(:employee, company:) }
  let(:payroll_item) do
    create(:payroll_item, :with_check, company:, pay_period:, employee:, check_number: "7101")
  end
  let(:printer_profile) do
    PrinterProfile.create!(
      organization: company.organization,
      name: "Payroll Office",
      check_stock_type: company.check_stock_type,
      check_offset_x: 0,
      check_offset_y: 0
    )
  end
  let(:stored) { {} }
  let(:storage) do
    instance_double(R2StorageService).tap do |service|
      allow(service).to receive(:upload) { |key, io, **| stored[key] = io.read }
      allow(service).to receive(:download) { |key| stored[key] }
      allow(service).to receive(:delete) { |key| stored.delete(key) }
    end
  end

  def create_generation
    CheckPrintGeneration.create!(
      company:, pay_period:, requested_by: user, printer_profile:,
      idempotency_key: SecureRandom.uuid, request_digest: SecureRandom.hex(32),
      payroll_item_ids: [ payroll_item.id ], non_employee_check_ids: [],
      printer_profile_lock_version: printer_profile.lock_version,
      starting_slot: 1, total_items: 1
    )
  end

  before do
    allow(R2StorageService).to receive(:new).and_return(storage)
  end

  it "moves through real phases and links exactly one immutable package" do
    generation = create_generation
    job = described_class.new(generation.id)
    phases = []
    allow_any_instance_of(CheckPrintGeneration).to receive(:advance!).and_wrap_original do |method, phase, **args|
      phases << phase
      method.call(phase, **args)
    end

    job.perform_now

    generation.reload
    expect(generation).to have_attributes(status: "ready", phase: "ready", completed_items: 1)
    expect(generation.check_print_run).to be_present
    expect(generation.worker_job_id).to eq(job.job_id)
    expect(generation.check_print_run.manifest.sole.fetch("render_input_digest")).to match(/\A[0-9a-f]{64}\z/)
    expect(CheckPrintRun.where(pay_period:).count).to eq(1)
    expect(phases).to include("validating", "rendering", "assembling", "uploading", "verifying")

    described_class.perform_now(generation.id)
    expect(CheckPrintRun.where(pay_period:).count).to eq(1)
  end

  it "stores a generated package where a separate staging web process can download it" do
    root = Pathname(Dir.mktmpdir("staging-check-print-"))
    stub_const("R2StorageService::STAGING_STORAGE_ROOT", root)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DEPLOYMENT_ENV").and_return("staging")
    allow(ENV).to receive(:[]).with("R2_STORAGE_BACKEND").and_return("local")
    allow(ENV).to receive(:[]).with("ACTIVE_STORAGE_SERVICE").and_return("local")
    allow(R2StorageService).to receive(:new).and_call_original

    begin
      generation = create_generation
      described_class.perform_now(generation.id)

      run = generation.reload.check_print_run
      expect(generation.status).to eq("ready")
      expect(run).to be_present
      pdf = R2StorageService.new.download(run.storage_key)
      expect(pdf).to start_with("%PDF")
      expect(Digest::SHA256.hexdigest(pdf)).to eq(run.sha256)
      expect(pdf.bytesize).to eq(run.byte_size)
    ensure
      FileUtils.remove_entry(root)
    end
  end

  it "fails safely and removes the artifact if check data changes during generation" do
    generation = create_generation
    allow(storage).to receive(:upload) do |key, io, **|
      stored[key] = io.read
      employee.update!(first_name: "Changed")
    end

    described_class.perform_now(generation.id)

    expect(generation.reload).to have_attributes(status: "failed", phase: "failed", error_code: "source_changed")
    expect(generation.error_message).to include("different rendered check")
    expect(CheckPrintRun.where(pay_period:)).to be_empty
    expect(stored).to be_empty
  end

  it "fails safely and removes the artifact if calibration changes during generation" do
    generation = create_generation
    allow(storage).to receive(:upload) do |key, io, **|
      stored[key] = io.read
      printer_profile.update!(check_offset_x: 0.1)
    end

    described_class.perform_now(generation.id)

    expect(generation.reload).to have_attributes(status: "failed", error_code: "source_changed")
    expect(generation.error_message).to include("changed after you opened")
    expect(CheckPrintRun.where(pay_period:)).to be_empty
    expect(stored).to be_empty
  end

  it "does not expose storage details when artifact verification fails" do
    generation = create_generation
    allow(storage).to receive(:download).and_return("corrupt")
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(generation.id)

    expect(generation.reload).to have_attributes(status: "failed", error_code: "generation_failed")
    expect(generation.error_message).to eq(
      "The package could not be generated. No checks were marked printed. Review the selection and try again."
    )
    expect(CheckPrintRun.where(pay_period:)).to be_empty
    expect(stored).to be_empty
  end

  it "does not classify an internal argument error as a source change" do
    generation = create_generation
    service = instance_double(CheckPrintRunGenerationService)
    allow(CheckPrintRunGenerationService).to receive(:new).and_return(service)
    allow(service).to receive(:call).and_raise(ArgumentError, "private parser detail")
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(generation.id)

    expect(generation.reload).to have_attributes(status: "failed", error_code: "generation_failed")
    expect(generation.error_message).not_to include("private parser detail")
  end

  it "cannot finalize a package after recovery ends the worker lease" do
    generation = create_generation
    allow(storage).to receive(:download) do |key|
      generation.update_column(:updated_at, 31.minutes.ago)
      CheckPrintGenerationRecoveryJob.perform_now
      stored[key]
    end
    allow(Rails.logger).to receive(:info)

    described_class.perform_now(generation.id)

    expect(generation.reload).to have_attributes(status: "failed", error_code: "generation_abandoned")
    expect(CheckPrintRun.where(pay_period:)).to be_empty
    expect(stored).to be_empty
  end
end
