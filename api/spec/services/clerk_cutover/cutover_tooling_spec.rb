# frozen_string_literal: true

require "rails_helper"
require "tempfile"

RSpec.describe "ClerkCutover preflight, inventory, and manifest builders" do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let!(:admin_user) do
    create(
      :user,
      company: company,
      organization: organization,
      email: "leon@example.com",
      clerk_id: "user_dev_admin",
      clerk_invitation_id: "inv_dev_admin",
      role: "super_admin",
      active: true
    )
  end
  let!(:pending_user) do
    create(
      :user,
      company: company,
      organization: organization,
      email: "pending@example.com",
      clerk_id: "pending_12345",
      invitation_status: "pending",
      role: "client",
      active: true
    )
  end
  let!(:inactive_user) do
    create(
      :user,
      company: company,
      organization: organization,
      email: "inactive@example.com",
      clerk_id: "user_dev_inactive",
      role: "accountant",
      active: false
    )
  end

  describe ClerkCutover::InventoryService do
    it "builds a read-only inventory with suggested dispositions, invitation id, and independent-review flags" do
      inventory = described_class.new.generate

      expect(inventory["summary"]).to include(
        "total_users" => 3,
        "active_users" => 2,
        "inactive_users" => 1,
        "pending_invitations" => 1,
        "bound_active_users" => 1,
        "unbound_active_users" => 1,
        "requires_independent_review" => 1
      )
      expect(inventory["summary"].to_json).not_to include("leon@example.com")

      admin_row = inventory["users"].find { |row| row["user_id"] == admin_user.id }
      expect(admin_row).to include(
        "old_clerk_id" => "user_dev_admin",
        "old_clerk_invitation_id" => "inv_dev_admin",
        "suggested_disposition" => "migrate",
        "disposition" => nil,
        "requires_independent_review" => true
      )

      pending_row = inventory["users"].find { |row| row["user_id"] == pending_user.id }
      expect(pending_row["suggested_disposition"]).to eq("re-invite")

      inactive_row = inventory["users"].find { |row| row["user_id"] == inactive_user.id }
      expect(inactive_row["suggested_disposition"]).to eq("skip_inactive")
    end

    it "refuses to write without write: true and tightens an existing 0644 file to 0600 when enabled" do
      Tempfile.create([ "inventory", ".json" ]) do |file|
        File.chmod(0o644, file.path)
        expect(File.stat(file.path).mode & 0o777).to eq(0o644)

        expect {
          described_class.new.write!(path: file.path)
        }.to raise_error(ClerkCutover::InventoryService::WriteRefusedError)

        summary = described_class.new.write!(path: file.path, write: true)
        expect(summary["total_users"]).to eq(3)
        expect(File.stat(file.path).mode & 0o777).to eq(0o600)
        expect(JSON.parse(File.read(file.path))["users"].length).to eq(3)
      end
    end
  end

  describe ClerkCutover::PreflightService do
    let(:env) do
      {
        "CLERK_ISSUER" => "https://smiling-fox-12.clerk.accounts.dev",
        "CLERK_AUTHORIZED_PARTIES" => "https://Payroll.Shimizu-Technology.com:443"
      }
    end

    it "passes when all active bound clerk_ids exist in source Clerk, zero users have TOTP enrolled, and target probes pass" do
      source_client = instance_double(
        ClerkCutover::ClerkClient,
        list_users: [
          { "id" => "user_dev_admin", "totp_enabled" => false, "two_factor_enabled" => false },
          { "id" => "user_dev_inactive", "totp_enabled" => false, "two_factor_enabled" => false }
        ]
      )
      target_client = instance_double(
        ClerkCutover::ClerkClient,
        fetch_jwks: [ { "kid" => "kid_live_1" } ],
        fetch_instance: { "id" => "ins_live_123" }
      )

      report = described_class.new(
        env: env,
        source_client: source_client,
        target_client: target_client,
        target_issuer: "https://clerk.shimizu-technology.com"
      ).run

      expect(report).to be_passed
      expect(report.as_json.to_json).not_to include("leon@example.com")
    end

    it "fails preflight when any Clerk user has TOTP enrolled or a non-empty totp_secret" do
      source_client = instance_double(
        ClerkCutover::ClerkClient,
        list_users: [
          { "id" => "user_dev_admin", "totp_enabled" => false, "totp_secret" => "JBSWY3DPEHPK3PXP" }
        ]
      )

      report = described_class.new(env: env, source_client: source_client).run

      expect(report).not_to be_passed
      totp_check = report.failures.find { |check| check.name == "no Clerk user has TOTP enrolled" }
      expect(totp_check).to be_present
      expect(totp_check.metadata[:totp_enrolled_clerk_ids]).to eq([ "user_dev_admin" ])
    end

    it "fails preflight when an active bound local clerk_id is missing from source Clerk (never falling back to email)" do
      source_client = instance_double(
        ClerkCutover::ClerkClient,
        list_users: [
          {
            "id" => "user_different_id",
            "email_addresses" => [ { "email_address" => "leon@example.com" } ],
            "totp_enabled" => false
          }
        ]
      )

      report = described_class.new(env: env, source_client: source_client).run

      expect(report).not_to be_passed
      reconcile_check = report.failures.find { |check| check.name == "every active bound local clerk_id exists in source Clerk" }
      expect(reconcile_check.metadata[:orphaned_clerk_ids]).to eq([ "user_dev_admin" ])
    end
  end

  describe ClerkCutover::ImportBuilder do
    let(:reviewed_inventory) do
      {
        "users" => [
          { "user_id" => admin_user.id, "old_clerk_id" => "user_dev_admin", "email" => "leon@example.com", "disposition" => "migrate", "batch" => "0" },
          { "user_id" => pending_user.id, "old_clerk_id" => "pending_12345", "email" => "pending@example.com", "disposition" => "re-invite", "batch" => "1" },
          { "user_id" => inactive_user.id, "old_clerk_id" => "user_dev_inactive", "email" => "inactive@example.com", "disposition" => "skip_inactive", "batch" => "1" }
        ]
      }
    end
    let(:clerk_csv_export) do
      <<~CSV
        id,first_name,last_name,primary_email_address,password_digest,password_hasher,totp_enabled,totp_secret
        user_dev_admin,Leon,Shimizu,leon@example.com,$2a$10$examplehash,bcrypt,false,
        user_dev_inactive,Old,User,inactive@example.com,,bcrypt,false,
      CSV
    end

    it "builds clerk migrate import records with external_id = dev clerk_id and preserves password digests" do
      result = described_class.new(inventory: reviewed_inventory, clerk_export: clerk_csv_export, batch: "0").build

      expect(result[:records]).to eq([
        {
          "external_id" => "user_dev_admin",
          "email_address" => [ "leon@example.com" ],
          "first_name" => "Leon",
          "last_name" => "Shimizu",
          "password_digest" => "$2a$10$examplehash",
          "password_hasher" => "bcrypt"
        }
      ])
      expect(result[:summary]).to include("selected_for_import" => 1, "with_password_digest" => 1)
    end

    it "never matches by email when old_clerk_id is absent from the Clerk export" do
      wrong_id_csv = <<~CSV
        id,first_name,last_name,primary_email_address,password_digest,password_hasher,totp_enabled
        user_dev_somebody_else,Leon,Shimizu,leon@example.com,$2a$10$examplehash,bcrypt,false
      CSV

      expect {
        described_class.new(inventory: reviewed_inventory, clerk_export: wrong_id_csv).build
      }.to raise_error(ClerkCutover::ImportBuilder::ValidationError, /was not found in the Clerk Dashboard export/)
    end

    it "refuses to build an import entry when totp_enabled is true or totp_secret/backup_codes is non-empty" do
      totp_flag_csv = <<~CSV
        id,first_name,last_name,primary_email_address,password_digest,password_hasher,totp_enabled
        user_dev_admin,Leon,Shimizu,leon@example.com,$2a$10$examplehash,bcrypt,true
      CSV
      totp_secret_csv = <<~CSV
        id,first_name,last_name,primary_email_address,password_digest,password_hasher,totp_secret
        user_dev_admin,Leon,Shimizu,leon@example.com,$2a$10$examplehash,bcrypt,JBSWY3DPEHPK3PXP
      CSV
      backup_codes_csv = <<~CSV
        id,first_name,last_name,primary_email_address,password_digest,password_hasher,backup_codes
        user_dev_admin,Leon,Shimizu,leon@example.com,$2a$10$examplehash,bcrypt,"[""code1""]"
      CSV

      [ totp_flag_csv, totp_secret_csv, backup_codes_csv ].each do |csv|
        expect {
          described_class.new(inventory: reviewed_inventory, clerk_export: csv).build
        }.to raise_error(ClerkCutover::ImportBuilder::ValidationError, /has TOTP enrolled/)
      end
    end

    it "fails closed when the CSV or JSON export omits all recognized MFA/TOTP columns" do
      missing_mfa_csv = <<~CSV
        id,first_name,last_name,primary_email_address,password_digest,password_hasher
        user_dev_admin,Leon,Shimizu,leon@example.com,$2a$10$examplehash,bcrypt
      CSV
      missing_mfa_json = [
        {
          "id" => "user_dev_admin",
          "primary_email_address" => "leon@example.com"
        }
      ]

      expect {
        described_class.new(inventory: reviewed_inventory, clerk_export: missing_mfa_csv).build
      }.to raise_error(ClerkCutover::ImportBuilder::ValidationError, /missing recognized MFA\/TOTP columns/)

      expect {
        described_class.new(inventory: reviewed_inventory, clerk_export: missing_mfa_json).build
      }.to raise_error(ClerkCutover::ImportBuilder::ValidationError, /missing recognized MFA\/TOTP fields/)
    end

    it "refuses when any inventory row lacks an explicit disposition" do
      unreviewed = reviewed_inventory.deep_dup
      unreviewed["users"][0]["disposition"] = nil

      expect {
        described_class.new(inventory: unreviewed, clerk_export: clerk_csv_export).build
      }.to raise_error(ClerkCutover::ImportBuilder::ValidationError, /disposition must be one of/)
    end

    it "sets skip_password_requirement for OAuth/email-code users, refuses writes without write: true, and chmods existing 0644 files to 0600" do
      json_export = [
        {
          "id" => "user_dev_admin",
          "first_name" => "Leon",
          "primary_email_address_id" => "em_1",
          "email_addresses" => [ { "id" => "em_1", "email_address" => "leon@example.com" } ],
          "totp_enabled" => false
        }
      ]
      builder = described_class.new(inventory: reviewed_inventory, clerk_export: json_export)
      result = builder.build

      expect(result[:records].first).to include(
        "external_id" => "user_dev_admin",
        "skip_password_requirement" => true
      )
      expect(result[:records].first).not_to have_key("password_digest")

      Tempfile.create([ "import", ".json" ]) do |file|
        File.chmod(0o644, file.path)
        expect {
          builder.write!(path: file.path)
        }.to raise_error(ClerkCutover::ImportBuilder::WriteRefusedError)

        builder.write!(path: file.path, write: true)
        expect(File.stat(file.path).mode & 0o777).to eq(0o600)
      end
    end
  end

  describe ClerkCutover::RelinkManifestBuilder do
    it "builds a sealed email-free re-link manifest strictly by target external_id == old_clerk_id with SHA-256 digest and old_clerk_invitation_id" do
      target_users = [
        {
          "id" => "user_live_admin",
          "external_id" => "user_dev_admin",
          "email_addresses" => [ { "email_address" => "leon@example.com" } ]
        }
      ]

      result = described_class.new(target_users: target_users).build

      expect(result[:manifest]["matching_strategy"]).to eq("external_id")
      expect(result[:manifest]["entries"]).to eq([
        {
          "user_id" => admin_user.id,
          "old_clerk_id" => "user_dev_admin",
          "new_clerk_id" => "user_live_admin",
          "external_id" => "user_dev_admin",
          "old_clerk_invitation_id" => "inv_dev_admin"
        }
      ])
      expect(result[:manifest]["manifest_digest"]).to eq(
        ClerkCutover::RelinkService.compute_manifest_digest(result[:manifest]["entries"])
      )
      expect(result[:manifest].to_json).not_to include("leon@example.com")
    end

    it "fails when a target user only matches by email and lacks external_id" do
      target_users = [
        {
          "id" => "user_live_admin",
          "external_id" => nil,
          "email_addresses" => [ { "email_address" => "leon@example.com" } ]
        }
      ]

      expect {
        described_class.new(target_users: target_users).build
      }.to raise_error(ClerkCutover::RelinkManifestBuilder::ValidationError, /no target Clerk user found with external_id=user_dev_admin/)
    end

    it "refuses to write without write: true and tightens an existing 0644 file to 0600" do
      target_users = [ { "id" => "user_live_admin", "external_id" => "user_dev_admin" } ]
      builder = described_class.new(target_users: target_users)

      Tempfile.create([ "manifest", ".json" ]) do |file|
        File.chmod(0o644, file.path)
        expect {
          builder.write!(path: file.path)
        }.to raise_error(ClerkCutover::RelinkManifestBuilder::WriteRefusedError)

        builder.write!(path: file.path, write: true)
        expect(File.stat(file.path).mode & 0o777).to eq(0o600)
      end
    end
  end
end
