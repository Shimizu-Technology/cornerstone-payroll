# frozen_string_literal: true

require "rails_helper"

RSpec.describe PostEmployeePayStubsJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company) }
  let(:period) { create(:pay_period, :committed, company: company, committed_at: Time.utc(2026, 8, 1), start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 14), pay_date: Date.new(2026, 8, 20)) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, updated_at: Time.utc(2026, 8, 1)) }
  let(:item) { create(:payroll_item, pay_period: period, employee: employee, gross_pay: 1_200, net_pay: 960, payment_delivery_method: "direct_deposit") }
  let(:storage) { instance_double(R2StorageService, upload: true, delete: true) }
  let(:cutoff) { Time.utc(2026, 8, 19, 20) }
  let(:documents) { EmployeeDocument.where(payroll_item: item).order(:revision) }

  before do
    features = instance_double(CompanyFeatures, employee_portal_feature?: true, employee_stubs_enabled_since: period.pay_date)
    allow(CompanyFeatures).to receive(:for).and_return(features)
    allow(R2StorageService).to receive(:new).and_return(storage)
  end

  def run_at(time)
    travel_to(time) { described_class.perform_now }
  end

  it "posts exactly once at 6am Guam and freezes the employee PDF and fingerprint" do
    item
    expect { run_at(cutoff - 1.second) }.not_to change(EmployeeDocument, :count)
    expect { run_at(cutoff) }.to change(EmployeeDocument, :count).by(1)

    doc = documents.first
    expect(doc).to have_attributes(status: "posted", posted_at: cutoff, revision: 1, corrected: false)
    expect(storage).to have_received(:upload).with(doc.storage_key, satisfy do |bytes|
      text = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join
      Digest::SHA256.hexdigest(bytes) == doc.sha256 && text.include?("Direct deposit") && !text.include?("transfer not confirmed")
    end, content_type: "application/pdf").once
    expect { run_at(cutoff + 5.minutes) }.not_to change(EmployeeDocument, :count)
  end

  it "posts a new revision when only the employee's suffix changes" do
    item
    run_at(cutoff)
    original = documents.sole

    travel_to(cutoff + 1.minute) { employee.update!(name_suffix: "III") }
    expect { run_at(cutoff + 5.minutes) }.to change(EmployeeDocument, :count).by(1)

    replacement = documents.reload.last
    expect(original.reload).to be_replaced
    expect(replacement).to have_attributes(revision: 2, status: "posted", replaces_document: original)
    expect(replacement.payroll_facts_sha256).not_to eq(original.payroll_facts_sha256)
    expect(storage).to have_received(:upload).with(replacement.storage_key, satisfy do |bytes|
      PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join.include?(employee.legal_name)
    end, content_type: "application/pdf").once
    expect { run_at(cutoff + 10.minutes) }.not_to change(EmployeeDocument, :count)
  end

  it "waits for committed payroll and for assignment of the paper check number" do
    item.update_columns(payment_delivery_method: "paper_check")
    period.update_columns(status: "approved")
    expect { run_at(cutoff) }.not_to change(EmployeeDocument, :count)
    period.update_columns(status: "committed", committed_at: cutoff + 5.minutes)
    expect { run_at(cutoff + 5.minutes) }.not_to change(EmployeeDocument, :count)
    item.update_columns(check_number: "4012")
    expect { run_at(cutoff + 10.minutes) }.to change(EmployeeDocument, :count).by(1)
    expect(documents.first.payment_line).to eq("Check #4012")
  end

  it "withdraws a voided check until a numbered replacement and ignores payment evidence" do
    uploads = []
    allow(storage).to receive(:upload) do |key, *|
      uploads << key
      true
    end
    frozen_state = lambda do
      latest = documents.reload.last
      [ EmployeeDocument.count, latest.storage_key, latest.sha256, latest.payroll_facts_sha256, uploads.size ]
    end
    item
    run_at(cutoff)
    travel_to(cutoff + 1.minute) do
      DirectDepositPaymentConfirmation.create!(
        payroll_item: item, user: actor, settled_on: period.pay_date, bank_reference: "test confirmation"
      )
    end
    expect { run_at(cutoff + 5.minutes) }.not_to change(&frozen_state)

    item.update_columns(payment_delivery_method: "paper_check", check_number: "4012", updated_at: cutoff + 6.minutes)
    expect { run_at(cutoff + 10.minutes) }.to change(EmployeeDocument, :count).by(1)
    item.update_columns(voided: true, updated_at: cutoff + 11.minutes)
    original_check = documents.reload.last
    expect { run_at(cutoff + 15.minutes) }.to change { original_check.reload.status }.from("posted").to("withdrawn")
    expect(original_check.withdrawal_reason).to eq("void")
    expect(EmployeeDocument.posted.where(payroll_item: item)).to be_empty
    expect(storage).to have_received(:upload).twice
    item.update_columns(voided: false, check_number: "4013", updated_at: cutoff + 16.minutes)
    expect { run_at(cutoff + 20.minutes) }.to change(EmployeeDocument, :count).by(1)
    travel_to(cutoff + 21.minutes) do
      item.update_columns(check_printed_at: Time.current, updated_at: Time.current)
      item.mark_delivered!(user: actor, delivered_on: period.pay_date,
        delivery_method: CheckEvent::DELIVERY_EVIDENCE_TYPES.first, attestation: true)
    end
    expect { run_at(cutoff + 25.minutes) }.not_to change(&frozen_state)

    expect(documents.reload.pluck(:status)).to eq(%w[replaced replaced posted])
    expect(documents.pluck(:payment_line)).to eq([ "Direct deposit", "Check #4012", "Check #4013" ])
    expect(documents.last).to have_attributes(corrected: true, replaces_document_id: original_check.id)
  end

  it "revises the frozen PDF when staff corrects the pay date" do
    item
    run_at(cutoff)
    original = documents.first
    travel_to(cutoff + 10.minutes) do
      PayPeriodPayDateCorrectionService.call(pay_period: period, new_pay_date: period.pay_date + 1.day,
        reason: "Correct the pay date on the issued stub", actor: actor)
    end
    run_at(cutoff + 1.day)
    corrected = documents.reload.last
    expect(corrected).to have_attributes(corrected: true, replaces_document_id: original.id)
    expect(corrected.payroll_facts_sha256).not_to eq(original.payroll_facts_sha256)
    expect(storage).to have_received(:upload).with(corrected.storage_key, satisfy { |bytes|
      PDF::Reader.new(StringIO.new(bytes)).page(1).text.include?("08/21/2026")
    }, content_type: "application/pdf")
  end

  it "checks an unchanged fingerprint once after an unrelated update" do
    item.update_columns(updated_at: cutoff - 1.day)
    period.update_columns(updated_at: cutoff - 1.day)
    run_at(cutoff)
    doc = documents.first
    item.update_columns(updated_at: cutoff + 1.minute)
    expect { run_at(cutoff + 5.minutes) }.to change { doc.reload.payroll_facts_checked_at }.to(cutoff + 5.minutes)
    expect { run_at(cutoff + 10.minutes) }.not_to change { doc.reload.payroll_facts_checked_at }
    expect(storage).to have_received(:upload).once
  end

  it "reports a failed item and posts the remaining item" do
    item
    other = create(:payroll_item, pay_period: period, employee: create(:employee, company: company), gross_pay: 500,
      net_pay: 400, payment_delivery_method: "direct_deposit")
    error = ArgumentError.new("synthetic posting error")
    allow(storage).to receive(:upload).and_raise(error)
    allow(storage).to receive(:upload).with(include("/payroll_item_#{other.id}/"), anything, content_type: "application/pdf").and_return(true)
    allow(Rails.error).to receive(:report)

    expect { run_at(cutoff) }.to change(EmployeeDocument, :count).by(1)
    expect(EmployeeDocument.posted.find_by!(payroll_item: other)).to be_present
    expect(Rails.error).to have_received(:report).with(error, handled: true, context: { payroll_item_id: item.id })
  end

  it "skips the notice hook when backfilling older pay dates" do
    item
    allow(CompanyFeatures.for(company)).to receive(:employee_stubs_enabled_since).and_return(period.pay_date + 1.day)
    expect_any_instance_of(EmployeeDocuments::PostPayStub).not_to receive(:enqueue_employee_pay_stub_notice)
    expect { run_at(cutoff + 1.day) }.to change(EmployeeDocument, :count).by(1)
  end

  it "calls the notice hook when activation falls between the period end and pay date" do
    item
    allow(CompanyFeatures.for(company)).to receive(:employee_stubs_enabled_since).and_return(period.end_date + 3.days)
    expect_any_instance_of(EmployeeDocuments::PostPayStub).to receive(:enqueue_employee_pay_stub_notice)
    run_at(cutoff)
  end

  it "removes a newly uploaded PDF when a later posting step rolls back" do
    item
    allow_any_instance_of(EmployeeDocuments::PostPayStub).to receive(:enqueue_employee_pay_stub_notice)
      .and_raise(ArgumentError, "synthetic notice failure")
    expect { run_at(cutoff) }.not_to change(EmployeeDocument, :count)
    expect(storage).to have_received(:delete).with(include("/payroll_item_#{item.id}/")).once
  end

  it "withdraws reversed payroll and links a later full correction to the archived original" do
    item
    run_at(cutoff)
    original = documents.first
    period.update_columns(correction_status: "voided")
    expect { run_at(cutoff + 5.minutes) }.to change { original.reload.status }.from("posted").to("withdrawn")

    corrective_period = create(:pay_period, :committed, company: company, committed_at: cutoff + 6.minutes, start_date: period.start_date,
      end_date: period.end_date, pay_date: period.pay_date)
    corrective_item = create(:payroll_item, pay_period: corrective_period, employee: employee,
      gross_pay: 900, net_pay: 700, payment_delivery_method: "direct_deposit", financial_correction_origin_item: item)
    run_at(cutoff + 10.minutes)
    expect(original.reload).to be_replaced
    expect(EmployeeDocument.find_by!(payroll_item: corrective_item)).to have_attributes(
      status: "posted", revision: 1, corrected: true, replaces_document_id: original.id
    )
  end

  context "with a delta correction" do
    let(:delta_period) do
      create(:pay_period, :committed, company: company, committed_at: cutoff, start_date: period.start_date,
        end_date: period.end_date, pay_date: period.pay_date)
    end
    let(:delta) do
      create(:payroll_item, pay_period: delta_period, employee: employee, gross_pay: 100, net_pay: 80,
        payment_delivery_method: "direct_deposit", correction_for_payroll_item: item)
    end
    let(:delta_documents) { EmployeeDocument.where(payroll_item: delta).order(:revision) }

    it "holds the delta when its origin does not have an active stub" do
      delta
      item.update_columns(payment_delivery_method: "paper_check")
      allow(Rails.logger).to receive(:info).and_call_original

      expect { run_at(cutoff) }.not_to change(EmployeeDocument, :count)
      expect(storage).not_to have_received(:upload)
      expect(Rails.logger).to have_received(:info)
        .with("Employee pay stub waiting for origin document for payroll item #{delta.id}").once
    end

    it "holds the delta after a failed origin upload and posts it linked on the next successful run" do
      delta
      allow(storage).to receive(:upload)
        .with(include("/payroll_item_#{item.id}/"), anything, content_type: "application/pdf")
        .and_raise(ArgumentError, "synthetic upload failure")

      expect { run_at(cutoff) }.not_to change(EmployeeDocument, :count)
      expect(storage).not_to have_received(:upload)
        .with(include("/payroll_item_#{delta.id}/"), anything, content_type: "application/pdf")

      allow(storage).to receive(:upload)
        .with(include("/payroll_item_#{item.id}/"), anything, content_type: "application/pdf").and_return(true)
      expect { run_at(cutoff + 5.minutes) }.to change(EmployeeDocument, :count).by(2)
      original = documents.first
      expect(original).to be_posted
      expect(delta_documents.first).to have_attributes(status: "posted", revision: 1, corrected: true, replaces_document: original)
    end

    it "repairs an unlinked legacy copy with an unchanged, already checked fingerprint" do
      item
      run_at(cutoff)
      original = documents.first
      delta.update_columns(updated_at: cutoff - 1.day)
      delta_period.update_columns(updated_at: cutoff - 1.day)
      fingerprint = PayStubGenerator.new(delta, employee_copy: true).employee_payroll_facts_sha256
      legacy = EmployeeDocument.create!(company: company, payroll_item: delta, revision: 1, storage_key: "legacy.pdf",
        sha256: "0" * 64, posted_at: cutoff, payroll_facts_checked_at: cutoff, payroll_facts_sha256: fingerprint)

      expect { run_at(cutoff + 5.minutes) }.to change { delta_documents.count }.by(1)
      expect(legacy.reload).to be_replaced
      expect(original.reload).to be_posted
      expect(delta_documents.last).to have_attributes(status: "posted", revision: 2, corrected: true,
        replaces_document: original, payroll_facts_sha256: fingerprint)
      expect { run_at(cutoff + 10.minutes) }.not_to change { delta_documents.count }
    end
  end

  describe "printed YTD" do
    def posted_text(document)
      text = nil
      expect(storage).to have_received(:upload).with(document.storage_key, satisfy { |bytes|
        text = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n").gsub(/\s+/, " ")
      }, content_type: "application/pdf")
      text
    end

    it "revises a posted stub when an earlier check's change moves a YTD amount it prints, and only then" do
      earlier_period = create(:pay_period, :committed, company: company, committed_at: Time.utc(2026, 7, 20),
        start_date: Date.new(2026, 7, 18), end_date: Date.new(2026, 7, 31), pay_date: Date.new(2026, 8, 6))
      earlier = create(:payroll_item, pay_period: earlier_period, employee: employee, gross_pay: 1_000, net_pay: 800,
        payment_delivery_method: "direct_deposit")
      item
      run_at(cutoff)
      original = documents.sole

      earlier.update_columns(gross_pay: 1_100, net_pay: 880)
      item.update_columns(updated_at: cutoff + 1.minute)
      run_at(cutoff + 5.minutes)

      expect(documents.reload.pluck(:revision)).to eq([ 1, 2 ])
      expect(original.reload).to be_replaced
      expect(posted_text(documents.last)).to include("Gross Earnings $2,300.00", "Net Pay $1,840.00")
      item.update_columns(updated_at: cutoff + 6.minutes)
      expect { run_at(cutoff + 10.minutes) }.not_to change(EmployeeDocument, :count)
    end

    it "revises a later stub once when an earlier check moves one cent from bonus to salary" do
      earlier_period = create(:pay_period, :committed, company: company, committed_at: Time.utc(2026, 7, 20),
        start_date: Date.new(2026, 7, 18), end_date: Date.new(2026, 7, 31), pay_date: Date.new(2026, 8, 6))
      earlier = create(:payroll_item, :salary, pay_period: earlier_period, employee: employee, bonus: 150,
        gross_pay: 1_200, net_pay: 960, payment_delivery_method: "direct_deposit")
      item
      run_at(cutoff)
      expect(posted_text(documents.sole)).to include("$1,050.00", "$150.00")

      earlier.update_columns(bonus: 150.01)
      item.update_columns(updated_at: cutoff + 1.minute)
      expect { run_at(cutoff + 5.minutes) }.to change { documents.count }.by(1)
      expect(posted_text(documents.last)).to include("$1,049.99", "$150.01", "Gross Earnings $2,400.00")

      item.update_columns(updated_at: cutoff + 6.minutes)
      expect { run_at(cutoff + 10.minutes) }.not_to change { documents.count }
    end

    def record_legacy_fingerprint
      item.update_columns(additional_withholding: 0)
      run_at(cutoff)
      document = documents.sole
      generator = PayStubGenerator.new(item.reload, employee_copy: true)
      old_ytd = generator.send(:printed_ytd_facts, legacy: true).merge(taxes: [
        [ "Federal/Guam Income Tax", item.withholding_tax.to_d.round(2).to_s("F") ],
        [ "Social Security (6.2%)", item.social_security_tax.to_d.round(2).to_s("F") ],
        [ "Medicare (1.45%)", item.medicare_tax.to_d.round(2).to_s("F") ]
      ])
      digest = Digest::SHA256.hexdigest([ item.employee.legal_name, *generator.send(:employee_payroll_current_facts, legacy: true), old_ytd ].to_json)
      expect(digest).not_to eq(document.payroll_facts_sha256)
      EmployeeDocument.where(id: document.id).update_all(payroll_facts_sha256: digest)
      item.update_columns(updated_at: cutoff + 1.minute)
      document
    end

    it "keeps the frozen posted stub when the old fingerprint still matches" do
      original = record_legacy_fingerprint

      expect { run_at(cutoff + 5.minutes) }.not_to change { documents.count }
      expect(original.reload).to be_posted
      expect(original.revision).to eq(1)
    end

    it "revises a legacy posting when Guam income tax actually changes" do
      original = record_legacy_fingerprint
      item.update_columns(withholding_tax: item.withholding_tax + 1)

      expect { run_at(cutoff + 5.minutes) }.to change { documents.count }.by(1)
      expect(original.reload).to be_replaced
      expect(documents.last.revision).to eq(2)
    end

    it "revises a stub posted under an earlier fingerprint format once, then keeps it current" do
      item
      run_at(cutoff)
      EmployeeDocument.where(id: documents.sole.id).update_all(payroll_facts_sha256: Digest::SHA256.hexdigest("earlier format"))
      item.update_columns(updated_at: cutoff + 1.minute)

      expect { run_at(cutoff + 5.minutes) }.to change { documents.count }.by(1)
      expect(documents.last.payroll_facts_sha256).to eq(PayStubGenerator.new(item.reload, employee_copy: true).employee_payroll_facts_sha256)
      item.update_columns(updated_at: cutoff + 6.minutes)
      expect { run_at(cutoff + 10.minutes) }.not_to change { documents.count }
    end

    it "never downloads a stored PDF while posting or rechecking" do
      allow(storage).to receive(:download)
      earlier_period = create(:pay_period, :committed, company: company, committed_at: Time.utc(2026, 7, 20),
        start_date: Date.new(2026, 7, 18), end_date: Date.new(2026, 7, 31), pay_date: Date.new(2026, 8, 6))
      earlier = create(:payroll_item, pay_period: earlier_period, employee: employee, gross_pay: 1_000, net_pay: 800,
        payment_delivery_method: "direct_deposit")
      item
      run_at(cutoff)
      item.update_columns(updated_at: cutoff + 1.minute)
      run_at(cutoff + 5.minutes)
      earlier.update_columns(gross_pay: 1_100, net_pay: 880)
      item.update_columns(updated_at: cutoff + 6.minutes)
      run_at(cutoff + 10.minutes)
      EmployeeDocument.where(id: documents.last.id).update_all(payroll_facts_sha256: Digest::SHA256.hexdigest("earlier format"))
      item.update_columns(updated_at: cutoff + 11.minutes)
      run_at(cutoff + 15.minutes)

      expect(documents.reload.pluck(:revision)).to eq([ 1, 2, 3 ])
      expect(storage).not_to have_received(:download)
    end
  end

  def sql_statements
    count = 0
    counter = lambda do |*, payload|
      next if payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION])
      next if payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      count += 1
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  it "rechecks an unchanged stub in no more queries than before it checked printed YTD" do
    (1..6).each do |index|
      earlier_period = create(:pay_period, :committed, company: company, committed_at: Time.utc(2026, 1, 1),
        start_date: Date.new(2026, 1, 1) + (14 * index), end_date: Date.new(2026, 1, 13) + (14 * index),
        pay_date: Date.new(2026, 1, 16) + (14 * index))
      create(:payroll_item, pay_period: earlier_period, employee: employee, gross_pay: 1_200, net_pay: 960,
        payment_delivery_method: "direct_deposit")
    end
    item
    run_at(cutoff)
    item.update_columns(updated_at: cutoff + 1.minute)

    # Measured on the earlier fingerprint, which read only this check: 11.
    due = item.reload
    statements = travel_to(cutoff + 5.minutes) { sql_statements { EmployeeDocuments::PostPayStub.new(due).call } }
    expect(documents.sole.payroll_facts_checked_at).to eq(cutoff + 5.minutes)
    expect(statements).to be <= 11
  end

  it "leaves a reversed item withdrawn when there is no successor" do
    item
    run_at(cutoff)
    item.update_columns(payroll_reversed_at: cutoff + 1.minute, payroll_reversed_by_id: actor.id,
      payroll_reversal_reason: "Correct duplicate payroll")
    document = documents.first
    expect { run_at(cutoff + 5.minutes) }.to change { document.reload.status }.from("posted").to("withdrawn")
  end
end
