# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollTaxSyncJob, type: :job do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      tax_sync_status: "pending",
      tax_sync_idempotency_key: "cpr-test-job"
    )
  end
  let!(:payroll_item) do
    create(:payroll_item, pay_period: pay_period, employee: employee, gross_pay: 1000, net_pay: 800)
  end

  describe "#perform" do
    it "calls PayrollTaxSyncService" do
      sync_service = instance_double(PayrollTaxSyncService)
      allow(PayrollTaxSyncService).to receive(:new).with(pay_period).and_return(sync_service)
      allow(sync_service).to receive(:sync!)

      described_class.perform_now(pay_period.id)

      expect(sync_service).to have_received(:sync!)
    end

    it "skips if pay period not found" do
      expect(PayrollTaxSyncService).not_to receive(:new)
      described_class.perform_now(-1)
    end

    it "skips if already synced" do
      pay_period.update!(tax_sync_status: "synced")
      expect(PayrollTaxSyncService).not_to receive(:new)
      described_class.perform_now(pay_period.id)
    end

    it "skips if not committed" do
      pay_period.update_column(:status, "approved")
      expect(PayrollTaxSyncService).not_to receive(:new)
      described_class.perform_now(pay_period.id)
    end

    it "is enqueued to the default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end
  end
end
