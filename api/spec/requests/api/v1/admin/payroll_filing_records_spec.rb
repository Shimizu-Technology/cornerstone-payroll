# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll filing records", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:upload) { Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/client_portal_upload.txt"), "text/plain") }
  let(:source) do
    PayrollFilingSourceSnapshot::Result.new(
      snapshot: { schema_version: "v1", company_id: company.id },
      fingerprint: "c" * 64
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollFilingRecordsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollFilingRecordsController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::PayrollFilingRecordsController).to receive(:current_user).and_return(admin)
    allow(PayrollFilingSourceSnapshot).to receive(:new).and_return(instance_double(PayrollFilingSourceSnapshot, call: source))
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT)
  end

  it "returns no external record until submission evidence exists" do
    get "/api/v1/admin/payroll_filing_records", params: { filing_type: "w1", tax_year: 2026, quarter: 2 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("filing")).to be_nil
  end

  it "rejects an invalid filing identity" do
    get "/api/v1/admin/payroll_filing_records", params: { filing_type: "schedule_b", tax_year: 2026, quarter: 2 }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Unsupported filing type")
  end

  it "uploads private proof and records submission separately from agency acceptance" do
    packet = QuarterlyCompliancePacket.find_or_create_for!(company: company, year: 2026, quarter: 2, user: admin)
    packet.quarterly_compliance_tasks.find_by!(task_type: "w1").update!(status: "ready_to_file")

    expect do
      post "/api/v1/admin/payroll_filing_records/events", params: {
        filing_type: "w1",
        tax_year: 2026,
        quarter: 2,
        event_type: "submitted",
        occurred_at: Time.current.iso8601,
        reference_number: "W1-RECEIPT-123",
        preparer_name: "Dana Accountant",
        signer_name: "Client Owner",
        idempotency_key: SecureRandom.uuid,
        file: upload
      }
    end.to change(PayrollFilingEvent, :count).by(1).and change(ClientDocument, :count).by(1)

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("filing", "status")).to eq("submitted")
    document = ClientDocument.find(response.parsed_body.dig("filing", "events", 0, "evidence_document", "id"))
    expect(document).to have_attributes(category: "filing_evidence", visible_to_client: false)
    expect(AuditLog.where(action: "payroll_filing_records#submitted", record_id: PayrollFilingRecord.last.id)).to exist
  end

  it "reports when committed payroll changes after submission using the real source snapshot" do
    allow(PayrollFilingSourceSnapshot).to receive(:new).and_call_original
    packet = QuarterlyCompliancePacket.find_or_create_for!(company: company, year: 2026, quarter: 2, user: admin)
    packet.quarterly_compliance_tasks.find_by!(task_type: "w1").update!(status: "ready_to_file")

    post "/api/v1/admin/payroll_filing_records/events", params: {
      filing_type: "w1", tax_year: 2026, quarter: 2, event_type: "submitted",
      reference_number: "W1-SOURCE-1", preparer_name: "Dana Accountant",
      signer_name: "Client Owner", idempotency_key: SecureRandom.uuid, file: upload
    }
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("filing", "source_changed")).to eq(false)

    employee = create(:employee, company: company)
    period = create(
      :pay_period,
      :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 15),
      pay_date: Date.new(2026, 4, 20),
      committed_by_id: admin.id
    )
    create(
      :payroll_item,
      company: company,
      pay_period: period,
      employee: employee,
      gross_pay: 1_000,
      total_deductions: 200,
      net_pay: 800
    )

    get "/api/v1/admin/payroll_filing_records", params: { filing_type: "w1", tax_year: 2026, quarter: 2 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("filing", "source_changed")).to eq(true)
  end

  it "returns the original result when an identical transport request is replayed" do
    packet = QuarterlyCompliancePacket.find_or_create_for!(company: company, year: 2026, quarter: 2, user: admin)
    packet.quarterly_compliance_tasks.find_by!(task_type: "w1").update!(status: "ready_to_file")
    key = SecureRandom.uuid
    occurred_at = 1.minute.ago.change(sec: 0).iso8601
    event_params = {
      filing_type: "w1",
      tax_year: 2026,
      quarter: 2,
      event_type: "submitted",
      occurred_at: occurred_at,
      reference_number: "W1-REPLAY-123",
      preparer_name: "Dana Accountant",
      signer_name: "Client Owner",
      idempotency_key: key
    }

    post "/api/v1/admin/payroll_filing_records/events", params: event_params.merge(
      file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/client_portal_upload.txt"), "text/plain")
    )
    expect(response).to have_http_status(:created)

    expect do
      post "/api/v1/admin/payroll_filing_records/events", params: event_params.merge(
        file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/client_portal_upload.txt"), "text/plain")
      )
    end.not_to change(PayrollFilingEvent, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("filing", "events").length).to eq(1)
    expect(ClientDocument.where(category: "filing_evidence").count).to eq(1)
  end

  it "returns the original result when an identical request races with the first submission" do
    packet = QuarterlyCompliancePacket.find_or_create_for!(company: company, year: 2026, quarter: 2, user: admin)
    packet.quarterly_compliance_tasks.find_by!(task_type: "w1").update!(status: "ready_to_file")
    key = SecureRandom.uuid
    occurred_at = 1.minute.ago.change(sec: 0).iso8601
    event_params = {
      filing_type: "w1",
      tax_year: 2026,
      quarter: 2,
      event_type: "submitted",
      occurred_at: occurred_at,
      reference_number: "W1-RACE-123",
      preparer_name: "Dana Accountant",
      signer_name: "Client Owner",
      idempotency_key: key
    }

    post "/api/v1/admin/payroll_filing_records/events", params: event_params.merge(
      file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/client_portal_upload.txt"), "text/plain")
    )
    event = PayrollFilingEvent.find_by!(company_id: company.id, idempotency_key: key)
    stale_lookup = instance_double(ActiveRecord::Relation)
    allow(PayrollFilingEvent).to receive(:includes).with(:evidence_document).and_return(stale_lookup)
    allow(stale_lookup).to receive(:find_by).and_return(nil, event)

    expect do
      post "/api/v1/admin/payroll_filing_records/events", params: event_params.merge(
        file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/client_portal_upload.txt"), "text/plain")
      )
    end.not_to change(PayrollFilingEvent, :count)

    expect(response).to have_http_status(:ok), response.body
    expect(ClientDocument.where(category: "filing_evidence").count).to eq(1)
  end

  it "rejects reuse of an idempotency key for different evidence" do
    packet = QuarterlyCompliancePacket.find_or_create_for!(company: company, year: 2026, quarter: 2, user: admin)
    packet.quarterly_compliance_tasks.find_by!(task_type: "w1").update!(status: "ready_to_file")
    key = SecureRandom.uuid
    base_params = {
      filing_type: "w1", tax_year: 2026, quarter: 2, event_type: "submitted",
      occurred_at: 1.minute.ago.change(sec: 0).iso8601,
      reference_number: "W1-IDEMPOTENT-1", preparer_name: "Dana Accountant",
      signer_name: "Client Owner", idempotency_key: key
    }

    post "/api/v1/admin/payroll_filing_records/events", params: base_params.merge(
      file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/client_portal_upload.txt"), "text/plain")
    )
    expect(response).to have_http_status(:created)

    post "/api/v1/admin/payroll_filing_records/events", params: base_params.merge(
      reference_number: "W1-IDEMPOTENT-2",
      file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/client_portal_upload.txt"), "text/plain")
    )

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to match(/already used for different filing evidence/)
    expect(PayrollFilingEvent.count).to eq(1)
    expect(ClientDocument.where(category: "filing_evidence").count).to eq(1)
  end

  it "removes an uploaded proof file when readiness validation rejects the event" do
    expect do
      post "/api/v1/admin/payroll_filing_records/events", params: {
        filing_type: "w1",
        tax_year: 2026,
        quarter: 2,
        event_type: "submitted",
        reference_number: "NOT-READY",
        preparer_name: "Dana Accountant",
        signer_name: "Client Owner",
        idempotency_key: SecureRandom.uuid,
        file: upload
      }
    end.not_to change(ClientDocument, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to match(/Start the quarterly filing workflow/)
    expect(PayrollFilingRecord.count).to eq(0)
  end

  it "rolls back evidence and removes the uploaded file when audit recording fails" do
    packet = QuarterlyCompliancePacket.find_or_create_for!(company: company, year: 2026, quarter: 2, user: admin)
    packet.quarterly_compliance_tasks.find_by!(task_type: "w1").update!(status: "ready_to_file")
    allow(AuditLog).to receive(:record!).and_raise("audit unavailable")

    expect do
      expect do
        post "/api/v1/admin/payroll_filing_records/events", params: {
          filing_type: "w1", tax_year: 2026, quarter: 2, event_type: "submitted",
          reference_number: "ROLLBACK-1", preparer_name: "Dana Accountant",
          signer_name: "Client Owner", idempotency_key: SecureRandom.uuid, file: upload
        }
      end.to raise_error(RuntimeError, "audit unavailable")
    end.not_to change(ClientDocument, :count)

    expect(PayrollFilingRecord.count).to eq(0)
    expect(PayrollFilingEvent.count).to eq(0)
    expect(Dir.glob(R2StorageService::LOCAL_STORAGE_ROOT.join("**", "*")).select { |path| File.file?(path) }).to be_empty
  end
end
