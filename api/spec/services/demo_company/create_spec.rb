# frozen_string_literal: true

require "rails_helper"

RSpec.describe DemoCompany::Create do
  let(:organization) { create(:organization) }
  let(:home) { create(:company, organization: organization, name: "Firm HQ") }
  let(:admin) { create(:user, company: home, organization: organization, role: "admin") }

  def create_demo(actor: admin, fixture_key: "harbor-finch-kitchen", **options)
    described_class.new(organization: organization, actor: actor, name: "Harbor Finch Kitchen", fixture_key: fixture_key, **options).call
  end

  it "creates a ready, permanent, source-free demo and audits it" do
    company = create_demo(profile: { city: "Hagåtña", ein: "98-7654321" })

    expect(company).to be_demo
    expect(company).to be_active
    expect(company.migration_rehearsal_status).to eq("ready")
    expect(company.migration_source_company_id).to be_nil
    expect(company.test_workspace_expires_at).to be_nil
    expect(company.auto_create_fit_check).to be(false)
    expect(company.city).to eq("Hagåtña")
    expect(company.test_workspace_manifest).to include("demo_fixture_key" => "harbor-finch-kitchen")
    expect(company.employees).to be_empty
    expect(company.pay_periods).to be_empty
    log = AuditLog.find_by(action: "companies#create", record_id: company.id)
    expect(log).to be_present
    expect(log.metadata.to_json).not_to match(/demo|fixture|harbor-finch/i)
    expect(AuditLog.where("action LIKE ?", "%demo%")).to be_empty
    expect(RecordCreator.call(company)&.dig(:name)).to eq(admin.name)
  end

  it "does not count against the organization's live client cap" do
    organization.update!(client_limit: 1)
    home
    expect(create_demo).to be_persisted
  end

  it "is limited to organization admins of the same organization" do
    accountant = create(:user, company: home, organization: organization, role: "accountant")
    outsider = create(:user, company: create(:company), role: "admin")

    expect { create_demo(actor: accountant) }.to raise_error(ArgumentError, /organization administrator/)
    expect { create_demo(actor: outsider) }.to raise_error(ArgumentError, /organization administrator/)
    expect(Company.demo).to be_empty
  end

  it "refuses a duplicate or malformed fixture key" do
    create_demo
    expect { create_demo }.to raise_error(ArgumentError, /already exists/)
    expect { create_demo(fixture_key: "Bad Key") }.to raise_error(ArgumentError, /Fixture key/)
  end

  describe "workspace tools" do
    let(:demo) { create_demo }

    it "never archives, restores, retries or copies into a demo" do
      lifecycle = TestWorkspace::Lifecycle.new(company: demo, actor: admin)
      expect { lifecycle.archive! }.to raise_error(ArgumentError, /permanent/)
      expect { lifecycle.restore! }.to raise_error(ArgumentError, /permanent/)
      expect { TestWorkspace::Retry.new(company: demo, actor: admin).call }.to raise_error(ArgumentError)
      expect { MigrationRehearsal::Retry.new(company: demo, actor: admin).call }.to raise_error(ArgumentError)
      expect { TrainingReplay::Retry.new(company: demo, actor: admin).call }.to raise_error(ArgumentError)
      expect { TestWorkspace::SetupCloner.new(source_company: home, target_company: demo, actor: admin).call }
        .to raise_error(ArgumentError, /never copied/)
      expect do
        TestWorkspace::OpeningYtdCloner.new(source_company: home, company: demo, actor: admin, employees: {}, cutoff: nil).call
      end.to raise_error(ArgumentError, /never copied/)
      expect { TrainingReplay::Cloner.new(company: demo, actor: admin).call }.to raise_error(ArgumentError)
      expect(MigrationPromotion::Preview.new(rehearsal: demo).call.fetch(:blockers)).to include("Choose a ready migration rehearsal")
      expect(demo.reload).to have_attributes(active: true, test_workspace_archived_at: nil, test_workspace_expires_at: nil)
    end
  end
end
