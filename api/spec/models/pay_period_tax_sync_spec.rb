# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriod, "tax sync", type: :model do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }

  describe "validations" do
    it "allows valid tax_sync_status values" do
      %w[pending syncing synced failed].each do |status|
        pp = build(:pay_period, company: company, tax_sync_status: status)
        pp.valid?
        expect(pp.errors[:tax_sync_status]).to be_empty
      end
    end

    it "rejects invalid tax_sync_status" do
      pp = build(:pay_period, company: company, tax_sync_status: "bogus")
      expect(pp).not_to be_valid
      expect(pp.errors[:tax_sync_status]).to be_present
    end

    it "allows nil tax_sync_status" do
      pp = build(:pay_period, company: company, tax_sync_status: nil)
      pp.valid?
      expect(pp.errors[:tax_sync_status]).to be_empty
    end
  end

  describe "#generate_idempotency_key!" do
    it "generates a key based on id and committed_at" do
      pp = create(:pay_period, :committed, company: company)
      pp.generate_idempotency_key!
      expect(pp.tax_sync_idempotency_key).to match(/\Acpr-\d+-\d+\z/)
    end

    it "does not overwrite an existing key" do
      pp = create(:pay_period, :committed, company: company, tax_sync_idempotency_key: "existing-key")
      pp.generate_idempotency_key!
      expect(pp.tax_sync_idempotency_key).to eq("existing-key")
    end
  end

  describe "#mark_syncing!" do
    it "sets status to syncing and increments attempts" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "pending", tax_sync_attempts: 0)
      pp.mark_syncing!
      expect(pp.tax_sync_status).to eq("syncing")
      expect(pp.tax_sync_attempts).to eq(1)
    end
  end

  describe "#mark_synced!" do
    it "sets status to synced with timestamp" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "syncing")
      pp.mark_synced!
      expect(pp.tax_sync_status).to eq("synced")
      expect(pp.tax_synced_at).to be_present
      expect(pp.tax_sync_last_error).to be_nil
    end
  end

  describe "#mark_sync_failed!" do
    it "sets status to failed with error message" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "syncing")
      pp.mark_sync_failed!("Connection refused")
      expect(pp.tax_sync_status).to eq("failed")
      expect(pp.tax_sync_last_error).to eq("Connection refused")
    end

    it "truncates long error messages" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "syncing")
      pp.mark_sync_failed!("x" * 2000)
      expect(pp.tax_sync_last_error.length).to be <= 1000
    end
  end

  describe "#can_retry_sync?" do
    it "returns true for committed + failed" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "failed")
      expect(pp.can_retry_sync?).to be true
    end

    it "returns true for committed + pending" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "pending")
      expect(pp.can_retry_sync?).to be true
    end

    it "returns false for committed + synced" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "synced")
      expect(pp.can_retry_sync?).to be false
    end

    it "returns false for non-committed pay periods" do
      pp = create(:pay_period, :approved, company: company, tax_sync_status: "failed")
      expect(pp.can_retry_sync?).to be false
    end
  end

  describe "#max_attempts_reached?" do
    it "returns true when attempts >= MAX_SYNC_ATTEMPTS" do
      pp = create(:pay_period, :committed, company: company, tax_sync_attempts: 5)
      expect(pp.max_attempts_reached?).to be true
    end

    it "returns false when attempts < MAX_SYNC_ATTEMPTS" do
      pp = create(:pay_period, :committed, company: company, tax_sync_attempts: 3)
      expect(pp.max_attempts_reached?).to be false
    end
  end

  describe "state transitions" do
    it "follows the full success lifecycle: pending -> syncing -> synced" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "pending")
      pp.mark_syncing!
      expect(pp.tax_sync_status).to eq("syncing")
      expect(pp.tax_sync_attempts).to eq(1)

      pp.mark_synced!
      expect(pp.tax_sync_status).to eq("synced")
      expect(pp.tax_synced_at).to be_present
    end

    it "follows the failure + retry lifecycle: pending -> syncing -> failed -> pending -> syncing -> synced" do
      pp = create(:pay_period, :committed, company: company, tax_sync_status: "pending")
      pp.mark_syncing!
      pp.mark_sync_failed!("timeout")
      expect(pp.tax_sync_status).to eq("failed")
      expect(pp.tax_sync_attempts).to eq(1)

      # Manual retry
      pp.update!(tax_sync_status: "pending", tax_sync_last_error: nil)
      pp.mark_syncing!
      expect(pp.tax_sync_attempts).to eq(2)

      pp.mark_synced!
      expect(pp.tax_sync_status).to eq("synced")
    end
  end
end
