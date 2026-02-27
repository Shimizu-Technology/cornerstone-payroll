# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe PayrollTaxSyncService, type: :service do
  let(:company) { create(:company, name: "Acme Corp", ein: "12-3456789") }
  let(:employee) { create(:employee, company: company) }
  let(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      tax_sync_status: "pending",
      tax_sync_idempotency_key: "cpr-test-123"
    )
  end
  let!(:payroll_item) do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      gross_pay: 2400.00,
      net_pay: 1800.00,
      withholding_tax: 300.00,
      social_security_tax: 148.80,
      medicare_tax: 34.80,
      employer_social_security_tax: 148.80,
      employer_medicare_tax: 34.80
    )
  end

  subject(:service) { described_class.new(pay_period) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CST_INGEST_URL").and_return("https://cst.example.com/api/v1/ingest")
    allow(ENV).to receive(:[]).with("CST_API_TOKEN").and_return("test-token")
    allow(ENV).to receive(:[]).with("CST_SHARED_SECRET").and_return("shared-test-secret")
  end

  describe "#sync!" do
    context "when CST_INGEST_URL is not configured" do
      before do
        allow(ENV).to receive(:[]).with("CST_INGEST_URL").and_return(nil)
      end

      it "raises ConfigurationError" do
        expect { service.sync! }.to raise_error(PayrollTaxSyncService::ConfigurationError, /CST_INGEST_URL/)
      end

      it "marks the pay period as failed" do
        service.sync! rescue nil
        pay_period.reload
        expect(pay_period.tax_sync_status).to eq("failed")
      end
    end

    context "when pay period is not committed" do
      before { pay_period.update_column(:status, "approved") }

      it "raises SyncError" do
        expect { service.sync! }.to raise_error(PayrollTaxSyncService::SyncError, /not committed/)
      end
    end

    context "when pay period has no payroll items" do
      before { pay_period.payroll_items.destroy_all }

      it "raises SyncError" do
        expect { service.sync! }.to raise_error(PayrollTaxSyncService::SyncError, /no payroll items/)
      end
    end

    context "when CST returns 200" do
      before do
        stub_request(:post, "https://cst.example.com/api/v1/ingest")
          .to_return(status: 200, body: '{"status":"accepted"}')
      end

      it "marks the pay period as synced" do
        service.sync!
        pay_period.reload
        expect(pay_period.tax_sync_status).to eq("synced")
        expect(pay_period.tax_synced_at).to be_present
      end

      it "increments attempts" do
        service.sync!
        pay_period.reload
        expect(pay_period.tax_sync_attempts).to eq(1)
      end

      it "sends idempotency key header" do
        service.sync!
        expect(WebMock).to have_requested(:post, "https://cst.example.com/api/v1/ingest")
          .with(headers: { "Idempotency-Key" => "cpr-test-123" })
      end

      it "sends authorization header" do
        service.sync!
        expect(WebMock).to have_requested(:post, "https://cst.example.com/api/v1/ingest")
          .with(headers: { "Authorization" => "Bearer test-token" })
      end

      it "sends shared-secret header" do
        service.sync!
        expect(WebMock).to have_requested(:post, "https://cst.example.com/api/v1/ingest")
          .with(headers: { "X-Shared-Secret" => "shared-test-secret" })
      end
    end

    context "when CST returns 409 (duplicate/idempotent)" do
      before do
        stub_request(:post, "https://cst.example.com/api/v1/ingest")
          .to_return(status: 409, body: '{"error":"duplicate"}')
      end

      it "treats as success (idempotent)" do
        service.sync!
        pay_period.reload
        expect(pay_period.tax_sync_status).to eq("synced")
      end
    end

    context "when CST returns 422 (client error)" do
      before do
        stub_request(:post, "https://cst.example.com/api/v1/ingest")
          .to_return(status: 422, body: '{"error":"invalid payload"}')
      end

      it "raises SyncError and marks failed" do
        expect { service.sync! }.to raise_error(PayrollTaxSyncService::SyncError, /422/)
        pay_period.reload
        expect(pay_period.tax_sync_status).to eq("failed")
        expect(pay_period.tax_sync_last_error).to include("422")
      end
    end

    context "when CST returns 500 (server error)" do
      before do
        stub_request(:post, "https://cst.example.com/api/v1/ingest")
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "raises SyncError and marks failed" do
        expect { service.sync! }.to raise_error(PayrollTaxSyncService::SyncError, /500/)
        pay_period.reload
        expect(pay_period.tax_sync_status).to eq("failed")
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:post, "https://cst.example.com/api/v1/ingest")
          .to_raise(Errno::ECONNREFUSED)
      end

      it "raises SyncError and marks failed" do
        expect { service.sync! }.to raise_error(PayrollTaxSyncService::SyncError)
        pay_period.reload
        expect(pay_period.tax_sync_status).to eq("failed")
      end
    end
  end
end
