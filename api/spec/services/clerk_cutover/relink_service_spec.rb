# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClerkCutover::RelinkService do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let!(:user_a) do
    create(
      :user,
      company: company,
      organization: organization,
      email: "admin-a@example.com",
      clerk_id: "user_dev_a",
      clerk_invitation_id: "inv_dev_a",
      last_session_id_digest: Digest::SHA256.hexdigest("sess_dev_a"),
      role: "admin",
      active: true
    )
  end
  let!(:user_b) do
    create(
      :user,
      company: company,
      organization: organization,
      email: "client-b@example.com",
      clerk_id: "user_dev_b",
      last_session_id_digest: Digest::SHA256.hexdigest("sess_dev_b"),
      role: "client",
      active: true
    )
  end
  let(:valid_manifest) do
    {
      "version" => 1,
      "matching_strategy" => "external_id",
      "entries" => [
        {
          "user_id" => user_a.id,
          "old_clerk_id" => "user_dev_a",
          "new_clerk_id" => "user_live_a",
          "external_id" => "user_dev_a"
        },
        {
          "user_id" => user_b.id,
          "old_clerk_id" => "user_dev_b",
          "new_clerk_id" => "user_live_b",
          "external_id" => "user_dev_b"
        }
      ]
    }
  end

  describe "#dry_run" do
    it "validates an exact-one manifest without mutating users or audit logs" do
      service = described_class.new(manifest: valid_manifest)

      expect {
        result = service.dry_run
        expect(result).to be_passed
        expect(result.to_relink).to eq(2)
        expect(result.relinked).to eq(0)
        expect(result.errors).to be_empty
      }.not_to change(AuditLog, :count)

      expect(user_a.reload.clerk_id).to eq("user_dev_a")
      expect(user_b.reload.clerk_id).to eq("user_dev_b")
    end

    it "rejects duplicate new_clerk_id targets" do
      bad_manifest = valid_manifest.deep_dup
      bad_manifest["entries"][1]["new_clerk_id"] = "user_live_a"

      result = described_class.new(manifest: bad_manifest).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("duplicate new_clerk_id")
    end

    it "rejects unknown user_id, inactive users, and clerk_id mismatches" do
      inactive = create(:user, company: company, organization: organization, clerk_id: "user_dev_inactive", active: false)
      bad_manifest = {
        "entries" => [
          { "user_id" => user_a.id + 999_999, "old_clerk_id" => "user_dev_missing", "new_clerk_id" => "user_live_missing" },
          { "user_id" => inactive.id, "old_clerk_id" => "user_dev_inactive", "new_clerk_id" => "user_live_inactive" },
          { "user_id" => user_a.id, "old_clerk_id" => "user_dev_wrong", "new_clerk_id" => "user_live_a" }
        ]
      }

      result = described_class.new(manifest: bad_manifest).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join("\n")).to include("local user not found")
      expect(result.errors.join("\n")).to include("refusing to re-link inactive user")
      expect(result.errors.join("\n")).to include("local clerk_id mismatch")
    end

    it "rejects when an active bound local user is missing from the manifest unless allow_partial is true" do
      partial_manifest = {
        "entries" => [ valid_manifest["entries"].first ]
      }

      strict_result = described_class.new(manifest: partial_manifest).dry_run
      expect(strict_result).not_to be_passed
      expect(strict_result.errors.join(" ")).to include("active bound local user(s) missing from manifest")

      partial_result = described_class.new(manifest: partial_manifest, allow_partial: true).dry_run
      expect(partial_result).to be_passed
    end

    it "verifies target Clerk external_id when a target_client is supplied" do
      target_client = instance_double(
        ClerkCutover::ClerkClient,
        list_users: [
          { "id" => "user_live_a", "external_id" => "user_dev_a" },
          { "id" => "user_live_b", "external_id" => "user_dev_different" }
        ]
      )

      result = described_class.new(manifest: valid_manifest, target_client: target_client).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("external_id mismatch")
    end

    it "rejects when new_clerk_id is already assigned to another local user" do
      create(:user, company: company, organization: organization, clerk_id: "user_live_a", active: false)

      result = described_class.new(manifest: valid_manifest).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("already assigned")
    end
  end

  describe "#apply!" do
    it "refuses to write without explicit confirm: true" do
      expect {
        described_class.new(manifest: valid_manifest).apply!
      }.to raise_error(ClerkCutover::RelinkService::WriteRefusedError)

      expect(user_a.reload.clerk_id).to eq("user_dev_a")
    end

    it "re-links users strictly by user_id/external_id, clears session and invitation state, records security audit logs, and is idempotent" do
      service = described_class.new(manifest: valid_manifest)

      result = service.apply!(confirm: true)
      expect(result).to be_passed
      expect(result.relinked).to eq(2)
      expect(result.already_relinked).to eq(0)

      expect(user_a.reload.clerk_id).to eq("user_live_a")
      expect(user_a.last_session_id_digest).to be_nil
      expect(user_a.clerk_invitation_id).to be_nil
      expect(user_b.reload.clerk_id).to eq("user_live_b")
      expect(user_b.last_session_id_digest).to be_nil

      audit_logs = AuditLog.where(action: "users#clerk_production_relinked", event_category: "security").order(:record_id)
      expect(audit_logs.count).to eq(2)
      expect(audit_logs.map(&:record_id)).to contain_exactly(user_a.id, user_b.id)
      expect(audit_logs.first.metadata).to include("matching_strategy" => "external_id")

      # Idempotent re-run performs zero additional updates or audit writes.
      expect {
        rerun = service.apply!(confirm: true)
        expect(rerun).to be_passed
        expect(rerun.relinked).to eq(0)
        expect(rerun.already_relinked).to eq(2)
      }.not_to change(AuditLog, :count)
    end

    it "rolls back the entire transaction atomically if any single row fails during apply" do
      call_count = 0
      allow(AuditLog).to receive(:record!).and_wrap_original do |original, **kwargs|
        call_count += 1
        raise ActiveRecord::StatementInvalid, "simulated failure on second row" if call_count == 2

        original.call(**kwargs)
      end

      expect {
        described_class.new(manifest: valid_manifest).apply!(confirm: true)
      }.to raise_error(ActiveRecord::StatementInvalid, /simulated failure/)

      expect(user_a.reload.clerk_id).to eq("user_dev_a")
      expect(user_b.reload.clerk_id).to eq("user_dev_b")
      expect(AuditLog.where(action: "users#clerk_production_relinked").count).to eq(0)
    end
  end

  describe "#rollback!" do
    it "refuses to roll back without explicit confirm: true" do
      described_class.new(manifest: valid_manifest).apply!(confirm: true)

      expect {
        described_class.new(manifest: valid_manifest).rollback!
      }.to raise_error(ClerkCutover::RelinkService::WriteRefusedError)

      expect(user_a.reload.clerk_id).to eq("user_live_a")
    end

    it "restores old_clerk_id atomically, records rollback audit logs, and is idempotent" do
      service = described_class.new(manifest: valid_manifest)
      service.apply!(confirm: true)

      result = service.rollback!(confirm: true)
      expect(result).to be_passed
      expect(result.rolled_back).to eq(2)
      expect(user_a.reload.clerk_id).to eq("user_dev_a")
      expect(user_b.reload.clerk_id).to eq("user_dev_b")
      expect(AuditLog.where(action: "users#clerk_production_relink_rolled_back", event_category: "security").count).to eq(2)

      rerun = service.rollback!(confirm: true)
      expect(rerun).to be_passed
      expect(rerun.rolled_back).to eq(0)
      expect(rerun.already_rolled_back).to eq(2)
    end
  end
end
