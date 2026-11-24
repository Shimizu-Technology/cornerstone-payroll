# frozen_string_literal: true

require "rails_helper"

RSpec.describe Company, "demo purpose", type: :model do
  let(:organization) { create(:organization) }
  let(:live) { create(:company, organization: organization, name: "Live Client") }
  let(:demo) { create_demo_company(organization: organization) }

  def raw_update(company, sql)
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("UPDATE companies SET #{sql} WHERE id = #{company.id}")
    end
  end

  it "is a permanent, source-free test workspace that presents as a live client" do
    expect(demo).to be_test_workspace
    expect(demo).to be_demo
    expect(demo).not_to be_practice_copy
    expect(demo).not_to be_live_payroll
    expect(demo).not_to be_sandbox
    expect(demo).not_to be_migration_rehearsal
    expect(demo.test_workspace_purpose_label).to be_nil
    expect(demo).to be_test_workspace_ready
    expect(demo).not_to be_test_workspace_expired
    expect(demo).not_to be_test_workspace_read_only
    expect(Company.demo).to contain_exactly(demo)
    expect(Company.live_payroll).to contain_exactly(live)
    expect(Company.not_demo).to include(live)
    expect(Company.not_demo).not_to include(demo)
  end

  it "rejects a source client, expiry, archive or seal in validation and in the database" do
    batch = create(:historical_import_batch, company: live, status: "locked")
    { migration_source_company: live, migration_source_batch: batch, test_workspace_expires_at: 1.day.from_now,
      test_workspace_archived_at: Time.current, test_workspace_sealed_at: Time.current }.each do |attribute, value|
      demo.reload.assign_attributes(attribute => value)
      expect(demo).not_to be_valid, "expected #{attribute} to be rejected"
    end

    %w[test_workspace_expires_at test_workspace_archived_at test_workspace_sealed_at].each do |column|
      expect { raw_update(demo, "#{column} = NOW()") }.to raise_error(ActiveRecord::StatementInvalid, /companies_test_workspace_shape_check/)
    end
    expect { raw_update(demo, "migration_source_company_id = #{live.id}") }
      .to raise_error(ActiveRecord::StatementInvalid, /companies_test_workspace_shape_check/)
  end

  def raw_insert(columns)
    names = columns.keys.join(", ")
    values = columns.values.map { |value| ActiveRecord::Base.connection.quote(value) }.join(", ")
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute(<<~SQL)
        INSERT INTO companies (#{names}, created_at, updated_at) VALUES (#{values}, NOW(), NOW())
      SQL
    end
  end

  def company_columns(**overrides)
    { organization_id: organization.id, name: "Raw", pay_frequency: "biweekly", kind_of_employer: "N", employment_code: "R",
      check_stock_type: "top_check", payroll_environment: "migration_rehearsal", migration_rehearsal_status: "ready" }.merge(overrides)
  end

  it "rejects a source-free, null-purpose workspace in the database, with or without a slug" do
    expect { raw_update(live, "payroll_environment = 'migration_rehearsal', migration_rehearsal_status = 'ready', subdomain_slug = 'moved-live'") }
      .to raise_error(ActiveRecord::StatementInvalid, /check constraint/)
    expect { raw_update(live, "payroll_environment = 'migration_rehearsal', migration_rehearsal_status = 'ready'") }
      .to raise_error(ActiveRecord::StatementInvalid, /companies_test_workspace_shape_check/)
    expect { raw_insert(company_columns(subdomain_slug: "raw-slug")) }
      .to raise_error(ActiveRecord::StatementInvalid, /check constraint/)
    expect(live.reload).to be_live_payroll
  end

  it "requires a non-blank fixture key in the database" do
    [ {}, { "demo_fixture_key" => "" }, { "demo_fixture_key" => "   " }, { "purpose" => "demo" } ].each do |manifest|
      expect { raw_insert(company_columns(test_workspace_purpose: "demo", test_workspace_manifest: manifest.to_json)) }
        .to raise_error(ActiveRecord::StatementInvalid, /companies_test_workspace_shape_check/), "accepted #{manifest.inspect}"
    end
    expect { raw_insert(company_columns(test_workspace_purpose: "demo", test_workspace_manifest: { "demo_fixture_key" => "raw-demo" }.to_json)) }
      .not_to raise_error
    expect(Company.demo.where("test_workspace_manifest ->> 'demo_fixture_key' = 'raw-demo'")).to exist
  end

  it "requires a fixture key and keeps it immutable" do
    expect(build(:company, organization: organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "demo", migration_rehearsal_status: "ready")).not_to be_valid

    demo.test_workspace_manifest = demo.test_workspace_manifest.merge("demo_fixture_key" => "other-key")
    expect(demo).not_to be_valid
    expect { raw_update(demo, %(test_workspace_manifest = '{"demo_fixture_key":"other-key"}'::jsonb)) }
      .to raise_error(ActiveRecord::StatementInvalid, /demo fixture keys are immutable/)
  end

  it "keeps fixture keys unique within an organization" do
    demo
    expect do
      ActiveRecord::Base.transaction(requires_new: true) { create_demo_company(organization: organization, name: "Second") }
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(create_demo_company(organization: create(:organization), name: "Elsewhere")).to be_persisted
  end

  it "blocks live/demo conversion and conversion to another workspace purpose" do
    demo.payroll_environment = "live"
    demo.test_workspace_purpose = nil
    demo.migration_rehearsal_status = nil
    expect(demo).not_to be_valid

    demo.reload.test_workspace_purpose = "sandbox"
    expect(demo).not_to be_valid

    expect do
      raw_update(demo, "payroll_environment = 'live', test_workspace_purpose = NULL, migration_rehearsal_status = NULL")
    end.to raise_error(ActiveRecord::StatementInvalid, /cannot be converted/)
    expect do
      raw_update(live, "payroll_environment = 'migration_rehearsal', test_workspace_purpose = 'demo', migration_rehearsal_status = 'ready'")
    end.to raise_error(ActiveRecord::StatementInvalid, /cannot be converted/)

    live.assign_attributes(payroll_environment: "migration_rehearsal", test_workspace_purpose: "demo",
      migration_rehearsal_status: "ready", test_workspace_manifest: { "demo_fixture_key" => "converted" })
    expect(live).not_to be_valid
  end

  it "keeps the source requirement for every other workspace purpose" do
    %w[sandbox training_replay backup_snapshot migration_rehearsal].each do |purpose|
      workspace = build(:company, organization: organization, payroll_environment: "migration_rehearsal",
        test_workspace_purpose: purpose, migration_rehearsal_status: "pending")
      expect(workspace).not_to be_valid
      expect(workspace.errors[:migration_source_company]).to be_present
    end

    sandbox = create(:company, organization: organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: live, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 90.days.from_now)
    expect(sandbox).to be_practice_copy
    expect(sandbox.test_workspace_purpose_label).to eq("General test workspace")
    expect { raw_update(sandbox, "migration_source_company_id = NULL") }
      .to raise_error(ActiveRecord::StatementInvalid, /companies_test_workspace_shape_check/)
    expect { raw_update(sandbox, "test_workspace_purpose = 'demo', test_workspace_expires_at = NULL, migration_source_company_id = NULL") }
      .to raise_error(ActiveRecord::StatementInvalid, /cannot be converted/)
  end

  it "allows a unique, unreserved subdomain slug on a demo but not on another workspace" do
    live.update!(subdomain_slug: "live-kitchen")
    expect(demo.update(subdomain_slug: "harbor-finch-demo")).to be(true)

    expect(create_demo_company(organization: organization, name: "Catering", fixture_key: "harbor-finch-catering")
      .update(subdomain_slug: "live-kitchen")).to be(false)
    expect(live.reload.update(subdomain_slug: "harbor-finch-demo")).to be(false)
    expect(demo.update(subdomain_slug: TenantSubdomainRegistry::RESERVED_SLUGS.first)).to be(false)
    expect { raw_update(live, "subdomain_slug = 'harbor-finch-demo'") }.to raise_error(ActiveRecord::RecordNotUnique)

    sandbox = create(:company, organization: organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: live, migration_rehearsal_status: "ready")
    expect { raw_update(sandbox, "subdomain_slug = 'sandbox-slug'") }
      .to raise_error(ActiveRecord::StatementInvalid, /company_subdomain_requires_live_payroll/)
  end

  it "stays out of the live client cap" do
    organization.update!(client_limit: 1)
    live
    demo
    expect(organization.companies.live_payroll.count).to eq(1)
  end

  it "starts ordinary, non-parallel pay periods that report committed runs like a live client" do
    period = create(:pay_period, company: demo)
    expect(period.parallel_run).to be(false)
    expect(PayPeriod.reportable_for_company(demo).to_sql).to include("committed")
  end
end
