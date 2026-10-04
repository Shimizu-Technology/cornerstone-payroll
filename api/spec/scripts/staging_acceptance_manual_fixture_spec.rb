# frozen_string_literal: true

require "rails_helper"
require_relative "../../../scripts/staging_acceptance/manual_fixture"

RSpec.describe StagingAcceptance::ManualFixture do
  let(:environment) do
    {
      "DEPLOYMENT_ENV" => "staging", "STAGING_SEED_ALLOWED" => "true", "STAGING_FIXTURE_NAMESPACE" => "staging-v2",
      "STAGING_ACCEPTANCE_FIXTURE" => described_class::FIXTURE, "STAGING_ACCEPTANCE_MODE" => "dry_run",
      "STAGING_SOURCE_INSTANCE_ID" => "10000000-0000-4000-8000-000000000001",
      "STAGING_ACTUAL_CLERK_ID" => "user_existingAcceptanceSubject", "STAGING_ACTUAL_EMAIL" => "operator@example.test",
      "STAGING_ACTUAL_NAME" => "Actual Test Operator"
    }
  end
  let(:fixture) { described_class.new(environment: environment) }
  let(:identity) do
    TimeTracking::ConnectionIdentity::Result.new(legacy: false, source_instance_id: environment.fetch("STAGING_SOURCE_INSTANCE_ID"),
      protocol: "shimizu_time_payroll", protocol_version: "1.0", capabilities: [ "payroll_cockpit" ])
  end

  describe "execution guards" do
    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(fixture).to receive(:database_name).and_return("cornerstone_payroll_staging_v2")
      allow(ActiveRecord::Base.connection).to receive(:select_value).with("SELECT current_database()").and_return("cornerstone_payroll_staging_v2")
      allow(ActiveRecord::Base.connection).to receive(:select_value).with("SELECT current_user").and_return("payroll_staging_v2")
      allow(ActiveRecord::Base.connection_db_config).to receive(:configuration_hash).and_return({ host: "payroll-db" })
    end

    it "allows only the exact guarded local staging target" do
      expect { fixture.guard_environment! }.not_to raise_error
    end

    %w[DEPLOYMENT_ENV STAGING_SEED_ALLOWED STAGING_FIXTURE_NAMESPACE STAGING_ACCEPTANCE_FIXTURE].each do |key|
      it "rejects a missing #{key} without writes or HTTP" do
        environment.delete(key)
        expect(TimeTracking::Client).not_to receive(:new)
        expect { fixture.run! }.to raise_error(described_class::GuardError)
        expect(User.count).to eq(0)
      end
    end

    it "rejects the real production database even with staging flags" do
      allow(ActiveRecord::Base.connection).to receive(:select_value).with("SELECT current_database()").and_return("cornerstone_payroll_production")
      expect { fixture.guard_environment! }.to raise_error(described_class::GuardError, /exact local staging database/)
    end

    it "rejects a lookalike database on a non-Compose host" do
      allow(ActiveRecord::Base.connection_db_config).to receive(:configuration_hash).and_return({ host: "production-db" })
      expect { fixture.guard_environment! }.to raise_error(described_class::GuardError, /Compose/)
    end

    it "rejects a mismatched database role" do
      allow(ActiveRecord::Base.connection).to receive(:select_value).with("SELECT current_user").and_return("production")
      expect { fixture.guard_environment! }.to raise_error(described_class::GuardError, /role/)
    end

    it "rejects clock acceleration" do
      environment["CERTIFICATION_CLOCK_FILE"] = "/tmp/fixture-clock"
      expect { fixture.guard_environment! }.to raise_error(described_class::GuardError, /real clock/)
    end

    it "rejects missing existing principal or installation pin" do
      environment["STAGING_ACTUAL_CLERK_ID"] = ""
      expect { fixture.guard_environment! }.to raise_error(described_class::GuardError, /principal/)
      environment["STAGING_ACTUAL_CLERK_ID"] = "user_existingAcceptanceSubject"
      environment["STAGING_SOURCE_INSTANCE_ID"] = ""
      expect { fixture.guard_environment! }.to raise_error(described_class::GuardError, /UUID/)
    end

    %w[payroll aire].each do |app|
      it "rejects a single-word principal name before any #{app} write or remote lookup" do
        database = described_class::DATABASES.fetch(app)
        allow(fixture).to receive(:database_name).and_return(database)
        allow(ActiveRecord::Base.connection).to receive(:select_value).with("SELECT current_database()").and_return(database)
        allow(ActiveRecord::Base.connection).to receive(:select_value).with("SELECT current_user").and_return("#{app}_staging_v2")
        allow(ActiveRecord::Base.connection_db_config).to receive(:configuration_hash).and_return({ host: "#{app}-db" })
        environment["STAGING_ACCEPTANCE_MODE"] = "apply"
        environment["STAGING_ACTUAL_NAME"] = "  Operator\t "
        expect(ApplicationRecord).not_to receive(:transaction)
        expect(User).not_to receive(:create!)
        expect(TimeTracking::Client).not_to receive(:new)

        expect { fixture.run! }.to raise_error(described_class::GuardError, /first and last names/)
        expect(User.count).to eq(0)
      end
    end
  end

  describe "additive Payroll fixture" do
    let!(:organization) { create(:organization, id: 910_001, slug: "aire-payroll-staging-v2", status: "active") }
    let!(:old_company) { create(:company, id: 910_001, organization: organization) }
    let!(:template) { create(:time_tracking_source, id: 910_001, company: old_company, historical_reconciliation_required: true) }
    let!(:old_period) { create(:pay_period, id: 910_001, company: old_company) }

    before do
      # The real execution guards are tested above. These tests exercise real
      # model writes transactionally in a task-owned test database only.
      allow(fixture).to receive(:guard_environment!)
      allow(fixture).to receive(:database_name).and_return("cornerstone_payroll_staging_v2")
      allow(fixture).to receive(:verify_installation!).and_return(identity)
    end

    it "keeps dry run read-only and omits the actual principal from output" do
      counts = [ User.count, Company.count, PayPeriod.count, TimeTrackingSource.count ]
      result = fixture.run!
      expect([ User.count, Company.count, PayPeriod.count, TimeTrackingSource.count ]).to eq(counts)
      expect(result[:mode]).to eq("dry_run")
      expect(result.to_json).not_to include(environment.fetch("STAGING_ACTUAL_CLERK_ID"), environment.fetch("STAGING_ACTUAL_EMAIL"))
    end

    it "creates scoped accountant access with pending business actions and explicit synthetic readiness" do
      environment["STAGING_ACCEPTANCE_MODE"] = "apply"
      original_period = old_period.attributes
      original_source = template.attributes
      result = fixture.run!
      operator = User.find(described_class::OPERATOR_ID)
      company = Company.find(described_class::OPERATOR_ID)
      maintainer = User.find(described_class::MAINTAINER_ID)
      employee = Employee.find(described_class::EMPLOYEE_ID)
      period = PayPeriod.find(described_class::OPERATOR_ID)
      source = TimeTrackingSource.find(described_class::OPERATOR_ID)

      expect(operator).to be_accountant
      expect(operator.accessible_company_ids).to eq([ company.id ])
      expect(operator.company_assignments.pluck(:company_id)).to eq([ company.id ])
      expect(StaffRolePolicy.allowed?(operator, :manage_client_configuration)).to be(false)
      expect(maintainer).not_to be_active
      expect(maintainer.clerk_id).to start_with("pending_")
      expect(period).to be_draft
      expect(period.run_purpose).to eq("adjustment")
      expect(period.payroll_items).to be_empty
      expect(period.approved_by_id).to be_nil
      expect(period.aire_payroll_calendar_period).to be_nil
      expect(source).to be_remote_identity_pinned
      expect(source.historical_reconciliation_required?).to be(false)
      expect(source.time_tracking_delegations).to be_empty
      expect(source.time_tracking_employee_mappings.first.source_user_uuid).to eq(described_class::EMPLOYEE_UUID)
      expect(employee.pay_rate).to eq(25)
      expect(employee).to be_document_readiness_required
      expect(employee.employee_document_requirements.pluck(:status).uniq).to eq([ "waived" ])
      expect(employee.employee_document_requirements.pluck(:reviewed_by_id).uniq).to eq([ maintainer.id ])
      expect(company.company_workweeks.first.confirmed_by_id).to eq(maintainer.id)
      expect(company.company_pay_schedules.first.confirmed_by_id).to eq(maintainer.id)
      expect(old_period.reload.attributes).to eq(original_period)
      expect(template.reload.attributes).to eq(original_source)
      expect(result[:existing_rows_unchanged]).to be(true)
      expect(result[:committed_periods_created]).to eq(0)
    end

    it "refuses to overwrite an existing local real-principal account" do
      create(:user, company: old_company, organization: organization, clerk_id: environment.fetch("STAGING_ACTUAL_CLERK_ID"))
      environment["STAGING_ACCEPTANCE_MODE"] = "apply"
      expect(fixture).not_to receive(:verify_installation!)
      expect { fixture.run! }.to raise_error(described_class::GuardError, /already has a local account/)
      expect(Company.exists?(described_class::OPERATOR_ID)).to be(false)
    end

    it "refuses a reserved collision without modifying it" do
      collision = create(:user, id: 920_999, company: old_company, organization: organization)
      original = collision.attributes
      environment["STAGING_ACCEPTANCE_MODE"] = "apply"
      expect { fixture.run! }.to raise_error(described_class::GuardError, /namespace/)
      expect(collision.reload.attributes).to eq(original)
      expect(Company.exists?(described_class::OPERATOR_ID)).to be(false)
    end

    it "rolls back the entire fixture if an existing protected row changes" do
      environment["STAGING_ACCEPTANCE_MODE"] = "apply"
      original = template.attributes
      allow(fixture).to receive(:create_payroll!).and_wrap_original do |method, *args|
        method.call(*args)
        template.update!(name: "Unexpected legacy update")
      end
      expect { fixture.run! }.to raise_error(described_class::GuardError, /rolling back/)
      expect(template.reload.attributes).to eq(original)
      expect(Company.exists?(described_class::OPERATOR_ID)).to be(false)
      expect(Employee.exists?(described_class::EMPLOYEE_ID)).to be(false)
    end
  end
end
