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
      clerk_invitation_id: "inv_dev_b",
      last_session_id_digest: Digest::SHA256.hexdigest("sess_dev_b"),
      role: "client",
      active: true
    )
  end
  let(:live_env) { { "CLERK_ISSUER" => "https://clerk.shimizu-technology.com" } }
  let(:target_client) do
    instance_double(
      ClerkCutover::ClerkClient,
      list_users: [
        { "id" => "user_live_a", "external_id" => "user_dev_a" },
        { "id" => "user_live_b", "external_id" => "user_dev_b" }
      ]
    )
  end

  def seal_manifest(entries)
    {
      "version" => 1,
      "matching_strategy" => "external_id",
      "manifest_digest" => described_class.compute_manifest_digest(entries),
      "entries" => entries
    }
  end

  let(:valid_entries) do
    [
      {
        "user_id" => user_a.id,
        "old_clerk_id" => "user_dev_a",
        "new_clerk_id" => "user_live_a",
        "external_id" => "user_dev_a",
        "old_clerk_invitation_id" => "inv_dev_a"
      },
      {
        "user_id" => user_b.id,
        "old_clerk_id" => "user_dev_b",
        "new_clerk_id" => "user_live_b",
        "external_id" => "user_dev_b",
        "old_clerk_invitation_id" => "inv_dev_b"
      }
    ]
  end
  let(:valid_manifest) { seal_manifest(valid_entries) }

  describe "#dry_run" do
    it "validates an exact-one sealed manifest without mutating users or audit logs" do
      service = described_class.new(manifest: valid_manifest, target_client: target_client, env: live_env)

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

    it "rejects an unsealed manifest missing manifest_digest" do
      unsealed = valid_manifest.except("manifest_digest")

      result = described_class.new(manifest: unsealed, env: live_env).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("missing or invalid SHA-256 manifest_digest")
    end

    it "rejects a tampered manifest when an entry is edited after sealing" do
      tampered = valid_manifest.deep_dup
      tampered["entries"][0]["new_clerk_id"] = "user_live_hijacked"

      result = described_class.new(manifest: tampered, env: live_env).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("Manifest digest mismatch")
    end

    it "rejects duplicate new_clerk_id targets" do
      entries = valid_entries.deep_dup
      entries[1]["new_clerk_id"] = "user_live_a"
      bad_manifest = seal_manifest(entries)

      result = described_class.new(manifest: bad_manifest, env: live_env).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("duplicate new_clerk_id")
    end

    it "rejects unknown user_id, inactive users, and clerk_id mismatches" do
      inactive = create(:user, company: company, organization: organization, clerk_id: "user_dev_inactive", active: false)
      bad_manifest = seal_manifest([
        { "user_id" => user_a.id + 999_999, "old_clerk_id" => "user_dev_missing", "new_clerk_id" => "user_live_missing" },
        { "user_id" => inactive.id, "old_clerk_id" => "user_dev_inactive", "new_clerk_id" => "user_live_inactive" },
        { "user_id" => user_a.id, "old_clerk_id" => "user_dev_wrong", "new_clerk_id" => "user_live_a" }
      ])

      result = described_class.new(manifest: bad_manifest, env: live_env).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join("\n")).to include("local user not found")
      expect(result.errors.join("\n")).to include("refusing to re-link inactive user")
      expect(result.errors.join("\n")).to include("local clerk_id mismatch")
    end

    it "rejects when an active bound local user is missing from the manifest unless allow_partial is true" do
      partial_manifest = seal_manifest([ valid_entries.first ])

      strict_result = described_class.new(manifest: partial_manifest, env: live_env).dry_run
      expect(strict_result).not_to be_passed
      expect(strict_result.errors.join(" ")).to include("active bound local user(s) missing from manifest")

      partial_result = described_class.new(manifest: partial_manifest, allow_partial: true, env: live_env).dry_run
      expect(partial_result).to be_passed
    end

    it "verifies target Clerk external_id when a target_client is supplied" do
      mismatched_client = instance_double(
        ClerkCutover::ClerkClient,
        list_users: [
          { "id" => "user_live_a", "external_id" => "user_dev_a" },
          { "id" => "user_live_b", "external_id" => "user_dev_different" }
        ]
      )

      result = described_class.new(manifest: valid_manifest, target_client: mismatched_client, env: live_env).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("external_id mismatch")
    end

    it "rejects when new_clerk_id is already assigned to another local user" do
      create(:user, company: company, organization: organization, clerk_id: "user_live_a", active: false)

      result = described_class.new(manifest: valid_manifest, env: live_env).dry_run

      expect(result).not_to be_passed
      expect(result.errors.join(" ")).to include("already assigned")
    end
  end

  describe "#apply!" do
    it "refuses to write without explicit confirm: true" do
      expect {
        described_class.new(manifest: valid_manifest, target_client: target_client, env: live_env).apply!
      }.to raise_error(ClerkCutover::RelinkService::WriteRefusedError)

      expect(user_a.reload.clerk_id).to eq("user_dev_a")
    end

    it "refuses to apply without a target_client so external_id is always verified" do
      result = described_class.new(manifest: valid_manifest, target_client: nil, env: live_env).apply!(confirm: true)

      expect(result).not_to be_passed
      expect(result.relinked).to eq(0)
      expect(result.errors.join(" ")).to include("Target Clerk client (TARGET_CLERK_SECRET_KEY) is required")
      expect(user_a.reload.clerk_id).to eq("user_dev_a")
    end

    it "refuses to apply a tampered manifest even when target_client and confirm are provided" do
      tampered = valid_manifest.deep_dup
      tampered["entries"][0]["new_clerk_id"] = "user_live_b"

      result = described_class.new(manifest: tampered, target_client: target_client, env: live_env).apply!(confirm: true)

      expect(result).not_to be_passed
      expect(result.relinked).to eq(0)
      expect(user_a.reload.clerk_id).to eq("user_dev_a")
    end

    it "refuses to apply while configured issuer is a Clerk dev issuer or matches source_issuer unless confirm_m3_1_deployed is set" do
      dev_env = { "CLERK_ISSUER" => "https://smiling-fox-12.clerk.accounts.dev" }
      dev_result = described_class.new(manifest: valid_manifest, target_client: target_client, env: dev_env).apply!(confirm: true)

      expect(dev_result).not_to be_passed
      expect(dev_result.relinked).to eq(0)
      expect(dev_result.errors.join(" ")).to include("Clerk dev issuer")
      expect(user_a.reload.clerk_id).to eq("user_dev_a")

      custom_source_env = { "CLERK_ISSUER" => "https://auth-source.example.com" }
      same_source_result = described_class.new(
        manifest: valid_manifest,
        target_client: target_client,
        env: custom_source_env,
        source_issuer: "https://auth-source.example.com"
      ).apply!(confirm: true)

      expect(same_source_result).not_to be_passed
      expect(same_source_result.errors.join(" ")).to include("equals source issuer")

      acknowledged_result = described_class.new(
        manifest: valid_manifest,
        target_client: target_client,
        env: dev_env,
        confirm_m3_1_deployed: true,
        operator: "leon@shimizu-technology.com"
      ).apply!(confirm: true)

      expect(acknowledged_result).to be_passed
      expect(acknowledged_result.relinked).to eq(2)
    end

    it "re-links users strictly by user_id/external_id, records operator in security audit logs, clears session/invitation, and is idempotent" do
      service = described_class.new(
        manifest: valid_manifest,
        target_client: target_client,
        env: live_env,
        operator: "leon@shimizu-technology.com"
      )

      result = service.apply!(confirm: true)
      expect(result).to be_passed
      expect(result.relinked).to eq(2)
      expect(result.already_relinked).to eq(0)

      expect(user_a.reload.clerk_id).to eq("user_live_a")
      expect(user_a.last_session_id_digest).to be_nil
      expect(user_a.clerk_invitation_id).to be_nil
      expect(user_b.reload.clerk_id).to eq("user_live_b")
      expect(user_b.last_session_id_digest).to be_nil
      expect(user_b.clerk_invitation_id).to be_nil

      audit_logs = AuditLog.where(action: "users#clerk_production_relinked", event_category: "security").order(:record_id)
      expect(audit_logs.count).to eq(2)
      expect(audit_logs.map(&:record_id)).to contain_exactly(user_a.id, user_b.id)
      expect(audit_logs.first.metadata).to include(
        "matching_strategy" => "external_id",
        "operator" => "leon@shimizu-technology.com"
      )

      # Idempotent re-run performs zero additional updates or audit writes.
      expect {
        rerun = service.apply!(confirm: true)
        expect(rerun).to be_passed
        expect(rerun.relinked).to eq(0)
        expect(rerun.already_relinked).to eq(2)
      }.not_to change(AuditLog, :count)
    end

    it "returns a failed result without raising and rolls back atomically on a concurrent clerk_id change" do
      lock_relation = User.lock
      allow(User).to receive(:lock).and_return(lock_relation)
      allow(lock_relation).to receive(:find).and_wrap_original do |original, id|
        record = original.call(id)
        if id == user_b.id
          # Simulate a concurrent writer modifying user_b after plan build but before lock acquisition.
          record.clerk_id = "user_dev_concurrently_changed"
        end
        record
      end

      result = described_class.new(
        manifest: valid_manifest,
        target_client: target_client,
        env: live_env
      ).apply!(confirm: true)

      expect(result).not_to be_passed
      expect(result.relinked).to eq(0)
      expect(result.errors.join(" ")).to include("changed concurrently before apply")
      expect(user_a.reload.clerk_id).to eq("user_dev_a")
      expect(user_b.reload.clerk_id).to eq("user_dev_b")
      expect(AuditLog.where(action: "users#clerk_production_relinked").count).to eq(0)
    end

    it "rolls back the entire transaction atomically if any single row fails during apply" do
      call_count = 0
      allow(AuditLog).to receive(:record!).and_wrap_original do |original, **kwargs|
        call_count += 1
        raise ActiveRecord::StatementInvalid, "simulated failure on second row" if call_count == 2

        original.call(**kwargs)
      end

      expect {
        described_class.new(manifest: valid_manifest, target_client: target_client, env: live_env).apply!(confirm: true)
      }.to raise_error(ActiveRecord::StatementInvalid, /simulated failure/)

      expect(user_a.reload.clerk_id).to eq("user_dev_a")
      expect(user_b.reload.clerk_id).to eq("user_dev_b")
      expect(AuditLog.where(action: "users#clerk_production_relinked").count).to eq(0)
    end
  end

  describe "#rollback!" do
    it "refuses to roll back without explicit confirm: true" do
      described_class.new(manifest: valid_manifest, target_client: target_client, env: live_env).apply!(confirm: true)

      expect {
        described_class.new(manifest: valid_manifest, env: live_env).rollback!
      }.to raise_error(ClerkCutover::RelinkService::WriteRefusedError)

      expect(user_a.reload.clerk_id).to eq("user_live_a")
    end

    it "restores old_clerk_id and clerk_invitation_id atomically, records operator in rollback audit logs, and is idempotent" do
      service = described_class.new(
        manifest: valid_manifest,
        target_client: target_client,
        env: live_env,
        operator: "dafne@cornerstone.test"
      )
      service.apply!(confirm: true)
      expect(user_a.reload.clerk_invitation_id).to be_nil

      result = service.rollback!(confirm: true)
      expect(result).to be_passed
      expect(result.rolled_back).to eq(2)
      expect(user_a.reload.clerk_id).to eq("user_dev_a")
      expect(user_a.clerk_invitation_id).to eq("inv_dev_a")
      expect(user_b.reload.clerk_id).to eq("user_dev_b")
      expect(user_b.clerk_invitation_id).to eq("inv_dev_b")

      rollback_logs = AuditLog.where(action: "users#clerk_production_relink_rolled_back", event_category: "security")
      expect(rollback_logs.count).to eq(2)
      expect(rollback_logs.first.metadata).to include(
        "operator" => "dafne@cornerstone.test",
        "restored_invitation" => true
      )

      rerun = service.rollback!(confirm: true)
      expect(rerun).to be_passed
      expect(rerun.rolled_back).to eq(0)
      expect(rerun.already_rolled_back).to eq(2)
    end

    it "returns a failed result without raising and rolls back atomically on a concurrent change during rollback" do
      service = described_class.new(manifest: valid_manifest, target_client: target_client, env: live_env)
      service.apply!(confirm: true)

      lock_relation = User.lock
      allow(User).to receive(:lock).and_return(lock_relation)
      allow(lock_relation).to receive(:find).and_wrap_original do |original, id|
        record = original.call(id)
        record.clerk_id = "user_live_changed_concurrently" if id == user_b.id
        record
      end

      result = service.rollback!(confirm: true)

      expect(result).not_to be_passed
      expect(result.rolled_back).to eq(0)
      expect(result.errors.join(" ")).to include("changed concurrently before rollback")
      expect(user_a.reload.clerk_id).to eq("user_live_a")
      expect(user_b.reload.clerk_id).to eq("user_live_b")
      expect(AuditLog.where(action: "users#clerk_production_relink_rolled_back").count).to eq(0)
    end
  end
end
