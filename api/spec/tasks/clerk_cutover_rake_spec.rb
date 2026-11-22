# frozen_string_literal: true

require "rails_helper"
require "rake"
require "tempfile"

RSpec.describe "clerk:* rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("clerk:jwks:clear")
  end

  around do |example|
    original_env = ENV.to_h
    example.run
  ensure
    ENV.replace(original_env)
  end

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  def sealed_manifest(entries)
    {
      "version" => 1,
      "matching_strategy" => "external_id",
      "manifest_digest" => ClerkCutover::RelinkService.compute_manifest_digest(entries),
      "entries" => entries
    }
  end

  describe "clerk:jwks:clear" do
    it "clears real RequestPathCache entries for current/old issuers and prints honest in-process restart guidance" do
      live_issuer = "https://clerk.shimizu-technology.com"
      old_issuer = "https://smiling-fox-12.clerk.accounts.dev"
      ENV["CLERK_ISSUER"] = live_issuer
      ENV["OLD_ISSUER"] = old_issuer

      live_key = ClerkTokenVerifier.jwks_cache_key(live_issuer)
      old_key = ClerkTokenVerifier.jwks_cache_key(old_issuer)
      RequestPathCache.store.write(live_key, [ { "kid" => "k1" } ])
      RequestPathCache.store.write(old_key, [ { "kid" => "k0" } ])
      RequestPathCache.store.write("clerk_jwks", [ { "kid" => "legacy" } ])

      expect { run_task("clerk:jwks:clear") }.to output(
        a_string_including(
          '"issuer":"https://clerk.shimizu-technology.com"',
          '"in_process_only":true',
          "cannot flush running Puma workers; restart or redeploy Puma"
        )
      ).to_stdout

      expect(RequestPathCache.store.read(live_key)).to be_nil
      expect(RequestPathCache.store.read(old_key)).to be_nil
      expect(RequestPathCache.store.read("clerk_jwks")).to be_nil
    end
  end

  describe "clerk:cutover:preflight" do
    it "aborts when preflight fails" do
      report = ClerkCutover::PreflightService::Report.new(
        checks: [
          ClerkCutover::PreflightService::Check.new(
            name: "no Clerk user has TOTP enrolled",
            passed: false,
            detail: "1 Clerk user(s) have TOTP enrolled",
            metadata: { totp_enrolled_count: 1 }
          )
        ]
      )
      service = instance_double(ClerkCutover::PreflightService, run: report)
      allow(ClerkCutover::PreflightService).to receive(:new).and_return(service)

      expect { run_task("clerk:cutover:preflight") }.to raise_error(SystemExit)
        .and output(a_string_including("FAIL  no Clerk user has TOTP enrolled")).to_stdout
        .and output(a_string_including("Clerk cutover preflight failed")).to_stderr
    end
  end

  describe "clerk:cutover:inventory" do
    it "prints counts only in read-only mode and refuses to write OUTPUT without WRITE=true" do
      ENV.delete("OUTPUT")
      ENV.delete("WRITE")

      expect { run_task("clerk:cutover:inventory") }.to output(
        a_string_including('"total_users":', '"output_written":false')
      ).to_stdout

      Tempfile.create([ "inv", ".json" ]) do |file|
        ENV["OUTPUT"] = file.path
        expect { run_task("clerk:cutover:inventory") }.to raise_error(SystemExit)
          .and output(a_string_including("Refusing to write inventory file without WRITE=true.")).to_stderr
      end
    end
  end

  describe "clerk:cutover:apply and clerk:cutover:rollback" do
    it "refuses to apply without APPLY=true" do
      ENV.delete("APPLY")
      ENV["MANIFEST"] = "/tmp/nonexistent.json"

      expect { run_task("clerk:cutover:apply") }.to raise_error(SystemExit)
        .and output(a_string_including("Refusing to apply Clerk re-link without APPLY=true.")).to_stderr
    end

    it "refuses to apply without TARGET_CLERK_SECRET_KEY" do
      ENV["APPLY"] = "true"
      ENV["MANIFEST"] = "/tmp/nonexistent.json"
      ENV.delete("TARGET_CLERK_SECRET_KEY")

      expect { run_task("clerk:cutover:apply") }.to raise_error(SystemExit)
        .and output(a_string_including("TARGET_CLERK_SECRET_KEY is required")).to_stderr
    end

    it "refuses to roll back without APPLY=true" do
      ENV.delete("APPLY")
      ENV["MANIFEST"] = "/tmp/nonexistent.json"

      expect { run_task("clerk:cutover:rollback") }.to raise_error(SystemExit)
        .and output(a_string_including("Refusing to roll back Clerk re-link without APPLY=true.")).to_stderr
    end

    it "applies and rolls back cleanly when APPLY=true, TARGET_CLERK_SECRET_KEY, and sealed manifest are provided" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      user = create(
        :user,
        company: company,
        organization: organization,
        clerk_id: "user_dev_apply_1",
        clerk_invitation_id: "inv_dev_apply_1",
        active: true
      )
      manifest = sealed_manifest([
        {
          "user_id" => user.id,
          "old_clerk_id" => "user_dev_apply_1",
          "new_clerk_id" => "user_live_apply_1",
          "external_id" => "user_dev_apply_1",
          "old_clerk_invitation_id" => "inv_dev_apply_1"
        }
      ])

      target_client = instance_double(
        ClerkCutover::ClerkClient,
        list_users: [ { "id" => "user_live_apply_1", "external_id" => "user_dev_apply_1" } ]
      )
      allow(ClerkCutover::ClerkClient).to receive(:new).with(secret_key: "sk_live_test").and_return(target_client)

      Tempfile.create([ "manifest", ".json" ]) do |file|
        file.write(JSON.generate(manifest))
        file.flush
        ENV["MANIFEST"] = file.path
        ENV["APPLY"] = "true"
        ENV["TARGET_CLERK_SECRET_KEY"] = "sk_live_test"
        ENV["CLERK_ISSUER"] = "https://clerk.shimizu-technology.com"
        ENV["OPERATOR"] = "leon@shimizu-technology.com"

        expect { run_task("clerk:cutover:apply") }.to output(
          a_string_including('"mode":"apply"', '"passed":true', '"relinked":1')
        ).to_stdout
        expect(user.reload.clerk_id).to eq("user_live_apply_1")
        expect(user.clerk_invitation_id).to be_nil

        expect { run_task("clerk:cutover:rollback") }.to output(
          a_string_including('"mode":"rollback"', '"passed":true', '"rolled_back":1')
        ).to_stdout
        expect(user.reload.clerk_id).to eq("user_dev_apply_1")
        expect(user.clerk_invitation_id).to eq("inv_dev_apply_1")
      end
    end
  end

  describe "clerk:cutover:build_import and clerk:cutover:build_manifest" do
    it "refuses to write build_import and build_manifest output files without WRITE=true" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      user = create(:user, company: company, organization: organization, email: "builder@example.com", clerk_id: "user_dev_build_1", active: true)

      Tempfile.create([ "inv", ".json" ]) do |inv_file|
        Tempfile.create([ "export", ".csv" ]) do |export_file|
          Tempfile.create([ "target", ".json" ]) do |target_file|
            Tempfile.create([ "out", ".json" ]) do |out_file|
              inv_file.write(JSON.generate("users" => [ { "user_id" => user.id, "old_clerk_id" => "user_dev_build_1", "disposition" => "migrate" } ]))
              inv_file.flush
              export_file.write("id,primary_email_address,totp_enabled\nuser_dev_build_1,builder@example.com,false\n")
              export_file.flush
              target_file.write(JSON.generate([ { "id" => "user_live_build_1", "external_id" => "user_dev_build_1" } ]))
              target_file.flush

              ENV["INVENTORY"] = inv_file.path
              ENV["EXPORT"] = export_file.path
              ENV["TARGET_USERS"] = target_file.path
              ENV["OUTPUT"] = out_file.path
              ENV.delete("WRITE")

              expect { run_task("clerk:cutover:build_import") }.to raise_error(SystemExit)
                .and output(a_string_including("Refusing to write import payload without WRITE=true.")).to_stderr

              expect { run_task("clerk:cutover:build_manifest") }.to raise_error(SystemExit)
                .and output(a_string_including("Refusing to write manifest file without WRITE=true.")).to_stderr
            end
          end
        end
      end
    end
  end

  describe "clerk:cutover:dry_run" do
    it "runs dry-run on a sealed manifest without writing to the database" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      user = create(:user, company: company, organization: organization, clerk_id: "user_dev_task_1", active: true)
      manifest = sealed_manifest([
        {
          "user_id" => user.id,
          "old_clerk_id" => "user_dev_task_1",
          "new_clerk_id" => "user_live_task_1",
          "external_id" => "user_dev_task_1"
        }
      ])

      Tempfile.create([ "manifest", ".json" ]) do |file|
        file.write(JSON.generate(manifest))
        file.flush
        ENV["MANIFEST"] = file.path

        expect { run_task("clerk:cutover:dry_run") }.to output(
          a_string_including('"mode":"dry_run"', '"passed":true', '"to_relink":1', '"relinked":0')
        ).to_stdout
        expect(user.reload.clerk_id).to eq("user_dev_task_1")
      end
    end
  end
end
