# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128030000_add_employee_lifecycle_foundations_columns_and_constraints")
require Rails.root.join("db/migrate/20261128030200_create_employee_verification_items")
require Rails.root.join("db/migrate/20261128030300_create_pay_period_verification_acknowledgements")
require Rails.root.join("db/migrate/20261128030400_create_employee_readiness_overrides")

RSpec.describe "Employee lifecycle PR 1 migrations and DB constraints" do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }

  describe AddEmployeeLifecycleFoundationsColumnsAndConstraints do
    let(:migration) { described_class.new }
    let(:status_probe) { :lifecycle_status_events_probe }
    let(:w4_probe) { :lifecycle_w4_elections_probe }

    before do
      stub_const("#{described_class}::STATUS_EVENTS_TABLE", status_probe)
      stub_const("#{described_class}::W4_TABLE", w4_probe)

      connection.create_table(status_probe) { |t| t.string :source, null: false }
      connection.add_check_constraint(
        status_probe,
        "source IN ('operator', 'production_migration')",
        name: described_class::STATUS_EVENTS_CONSTRAINT
      )

      connection.create_table(w4_probe) { |t| t.string :source, null: false }
      connection.add_check_constraint(
        w4_probe,
        "source IN ('staff', 'client_approved', 'employee_creation', 'legacy_profile', 'quickbooks_history', 'default_withholding')",
        name: described_class::W4_CONSTRAINT
      )
    end

    after do
      connection.drop_table(status_probe, if_exists: true)
      connection.drop_table(w4_probe, if_exists: true)
    end

    def insert_source(table, source)
      connection.execute("INSERT INTO #{table} (source) VALUES (#{connection.quote(source)})")
    end

    it "commits NOT VALID before VALIDATE and swaps only a validated constraint for both tables" do
      insert_source(status_probe, "operator")
      insert_source(w4_probe, "staff")

      validated_calls = []
      allow(migration).to receive(:validate_check_constraint).and_wrap_original do |method, table_arg, **kwargs|
        validated_calls << [ table_arg, kwargs[:name] ]
        if table_arg == status_probe
          expect(connection.check_constraint_exists?(status_probe, name: described_class::STATUS_EVENTS_CONSTRAINT)).to be(true)
          expect { insert_source(status_probe, "client_portal") }.to raise_error(ActiveRecord::StatementInvalid)
        elsif table_arg == w4_probe
          expect(connection.check_constraint_exists?(w4_probe, name: described_class::W4_CONSTRAINT)).to be(true)
          expect { insert_source(w4_probe, "client_direct") }.to raise_error(ActiveRecord::StatementInvalid)
        end
        method.call(table_arg, **kwargs)
      end

      migration.up

      expect(validated_calls).to eq([
        [ status_probe, described_class::STATUS_EXPANDED_TMP ],
        [ w4_probe, described_class::W4_EXPANDED_TMP ]
      ])

      status_constraints = connection.check_constraints(status_probe)
      expect(status_constraints.map(&:name)).to eq([ described_class::STATUS_EVENTS_CONSTRAINT ])
      expect(status_constraints.first).to be_validate
      insert_source(status_probe, "client_portal")
      expect { insert_source(status_probe, "bogus_source") }.to raise_error(ActiveRecord::StatementInvalid)

      w4_constraints = connection.check_constraints(w4_probe)
      expect(w4_constraints.map(&:name)).to eq([ described_class::W4_CONSTRAINT ])
      expect(w4_constraints.first).to be_validate
      insert_source(w4_probe, "client_direct")
      expect { insert_source(w4_probe, "bogus_source") }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "resumes interrupted temporary constraints idempotently" do
      connection.add_check_constraint(
        status_probe,
        "source IN ('operator', 'production_migration', 'client_portal')",
        name: described_class::STATUS_EXPANDED_TMP,
        validate: false
      )
      connection.add_check_constraint(
        w4_probe,
        "source IN ('staff', 'client_approved', 'client_direct', 'employee_creation', 'legacy_profile', 'quickbooks_history', 'default_withholding')",
        name: described_class::W4_EXPANDED_TMP,
        validate: false
      )

      2.times { migration.up }

      expect(connection.check_constraints(status_probe).map(&:name)).to eq([ described_class::STATUS_EVENTS_CONSTRAINT ])
      expect(connection.check_constraints(w4_probe).map(&:name)).to eq([ described_class::W4_CONSTRAINT ])
      insert_source(status_probe, "client_portal")
      insert_source(w4_probe, "client_direct")
    end

    it "preserves rows and cleans up failed temporary constraints if rollback sees new sources" do
      migration.up
      insert_source(w4_probe, "client_direct")

      expect { migration.send(:replace_source_constraint!, table: w4_probe, constraint_name: described_class::W4_CONSTRAINT, sources: described_class::ORIGINAL_W4_SOURCES, temporary_name: described_class::W4_ORIGINAL_TMP, known_temporaries: { described_class::W4_EXPANDED_TMP => described_class::EXPANDED_W4_SOURCES, described_class::W4_ORIGINAL_TMP => described_class::ORIGINAL_W4_SOURCES }) }
        .to raise_error(ActiveRecord::StatementInvalid)

      expect(connection.select_value("SELECT count(*) FROM #{w4_probe}")).to eq(1)
      expect(connection.check_constraints(w4_probe).map(&:name)).to eq([ described_class::W4_CONSTRAINT ])
      insert_source(w4_probe, "client_direct")
    end
  end

  describe "columns, indexes, and database-level constraints" do
    it "installs the new columns and concurrent tenant/readiness indexes" do
      employee_col = connection.columns(:employees).find { |c| c.name == "readiness_gate_enforced" }
      expect(employee_col).to have_attributes(sql_type: "boolean", null: false, default: "false")

      profile_cols = connection.columns(:client_operating_profiles).index_by(&:name)
      expect(profile_cols["lifecycle_mode_activated_at"]).to be_present
      expect(profile_cols["lifecycle_mode_activation_failed_at"]).to be_present
      expect(profile_cols["lifecycle_mode_activation_blockers"]).to have_attributes(sql_type: "jsonb", null: false)

      expect(connection.indexes(:employees).map(&:name)).to include("idx_employees_readiness_gate_enforced")
      expect(connection.indexes(:employee_w4_elections).find { |i| i.name == "idx_employee_w4_elections_tenant_key" })
        .to have_attributes(unique: true, columns: %w[id company_id])
      expect(connection.indexes(:admin_overrides).find { |i| i.name == "idx_admin_overrides_tenant_key" })
        .to have_attributes(unique: true, columns: %w[id company_id])
    end

    it "enforces CHECK and composite tenant FK constraints on all three new tables" do
      connection.transaction do
        company = create(:company)
        other_company = create(:company, organization: company.organization)
        actor = create(:user, company: company, organization: company.organization, role: "org_admin")
        employee = create(:employee, company: company)
        other_employee = create(:employee, company: other_company)
        period = create(:pay_period, company: company)
        other_period = create(:pay_period, company: other_company)

        # employee_verification_items: event_kind, status, self-supersession, composite FKs
        item = EmployeeVerificationItem.create!(
          company: company, employee: employee, event_kind: "new_hire", status: "pending_verification",
          source_actor: actor
        )
        other_item = EmployeeVerificationItem.create!(
          company: other_company, employee: other_employee, event_kind: "new_hire", status: "pending_verification",
          source_actor: actor
        )

        expect do
          connection.transaction(requires_new: true) do
            EmployeeVerificationItem.new(company: company, employee: employee, event_kind: "invalid_kind", status: "pending_verification").save!(validate: false)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /employee_verification_items_event_kind_check/)

        expect do
          connection.transaction(requires_new: true) do
            EmployeeVerificationItem.new(company: company, employee: employee, event_kind: "new_hire", status: "invalid_status").save!(validate: false)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /employee_verification_items_status_check/)

        expect do
          connection.transaction(requires_new: true) do
            EmployeeVerificationItem.new(company: company, employee: other_employee, event_kind: "new_hire", status: "pending_verification").save!(validate: false)
          end
        end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_employee_verification_items_employee/)

        expect do
          connection.transaction(requires_new: true) do
            item.update_columns(superseded_by_id: other_item.id)
          end
        end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_employee_verification_items_superseded_by/)

        expect do
          connection.transaction(requires_new: true) do
            item.update_columns(superseded_by_id: item.id)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /employee_verification_items_not_self_superseded_check/)

        # pay_period_verification_acknowledgements: status snapshot, unique pair, composite FKs
        ack = PayPeriodVerificationAcknowledgement.create!(
          company: company, pay_period: period, employee_verification_item: item, employee: employee,
          acknowledged_by: actor, acknowledged_at: Time.current,
          item_status_snapshot: "pending_verification", item_updated_at_snapshot: item.updated_at
        )
        expect(ack).to be_persisted

        expect do
          connection.transaction(requires_new: true) do
            PayPeriodVerificationAcknowledgement.new(
              company: company, pay_period: period, employee_verification_item: item, employee: employee,
              acknowledged_by: actor, acknowledged_at: Time.current,
              item_status_snapshot: "verified", item_updated_at_snapshot: item.updated_at
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /pay_period_verification_acks_status_snapshot_check/)

        expect do
          connection.transaction(requires_new: true) do
            PayPeriodVerificationAcknowledgement.new(
              company: company, pay_period: other_period, employee_verification_item: item, employee: employee,
              acknowledged_by: actor, acknowledged_at: Time.current,
              item_status_snapshot: "pending_verification", item_updated_at_snapshot: item.updated_at
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_pp_verification_acks_pay_period/)

        expect do
          connection.transaction(requires_new: true) do
            PayPeriodVerificationAcknowledgement.new(
              company: company, pay_period: period, employee_verification_item: other_item, employee: employee,
              acknowledged_by: actor, acknowledged_at: Time.current,
              item_status_snapshot: "pending_verification", item_updated_at_snapshot: other_item.updated_at
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_pp_verification_acks_item/)

        # employee_readiness_overrides: scope check, reason length check, partial unique, composite FKs
        admin_override = AdminOverride.create!(
          company: company, actor: actor, subject: employee, action: "employee_readiness_override#grant",
          reason: "Urgent payroll override while employee awaits SSN card",
          before_snapshot: {}, after_snapshot: {}, preflight_result: {}
        )
        other_admin_override = AdminOverride.create!(
          company: other_company, actor: actor, subject: other_employee, action: "employee_readiness_override#grant",
          reason: "Urgent payroll override for second test company",
          before_snapshot: {}, after_snapshot: {}, preflight_result: {}
        )
        other_w4 = EmployeeW4Election.create!(
          EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
            company: other_company, employee: other_employee, effective_on: period.pay_date,
            source: "default_withholding", reason: "Default withholding fixture"
          )
        )

        override = EmployeeReadinessOverride.create!(
          company: company, employee: employee, pay_period: period,
          missing_items_snapshot: [ "tax_form" ], default_w4_acknowledged: true,
          reason: "Approved urgent first paycheck while W-4 is in transit",
          granted_by: actor, granted_at: Time.current, admin_override: admin_override
        )
        expect(override).to be_persisted

        expect do
          connection.transaction(requires_new: true) do
            EmployeeReadinessOverride.new(
              company: company, employee: employee, pay_period: nil, expires_on: nil,
              reason: "Missing both pay period and expiration date",
              granted_by: actor, granted_at: Time.current, admin_override: admin_override
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /employee_readiness_overrides_scope_check/)

        expect do
          connection.transaction(requires_new: true) do
            EmployeeReadinessOverride.new(
              company: company, employee: employee, expires_on: Date.current + 7,
              reason: "short",
              granted_by: actor, granted_at: Time.current, admin_override: admin_override
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /employee_readiness_overrides_reason_length_check/)

        expect do
          connection.transaction(requires_new: true) do
            EmployeeReadinessOverride.new(
              company: company, employee: employee, pay_period: period,
              reason: "Duplicate active period override should fail unique index",
              granted_by: actor, granted_at: Time.current, admin_override: admin_override
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::RecordNotUnique, /idx_employee_readiness_overrides_active_period/)

        expect do
          connection.transaction(requires_new: true) do
            EmployeeReadinessOverride.new(
              company: company, employee: employee, expires_on: Date.current + 7,
              default_w4_election_id: other_w4.id,
              reason: "Cross-company W-4 reference must be rejected by composite FK",
              granted_by: actor, granted_at: Time.current, admin_override: admin_override
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_employee_readiness_overrides_w4_election/)

        expect do
          connection.transaction(requires_new: true) do
            EmployeeReadinessOverride.new(
              company: company, employee: employee, expires_on: Date.current + 7,
              reason: "Cross-company admin_override reference must be rejected",
              granted_by: actor, granted_at: Time.current, admin_override_id: other_admin_override.id
            ).save!(validate: false)
          end
        end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_employee_readiness_overrides_admin_override/)

        raise ActiveRecord::Rollback
      end
    end

    it "enables and forces RLS when staging policies on an already-enforced database" do
      connection.transaction do
        connection.execute("ALTER TABLE employee_account_links ENABLE ROW LEVEL SECURITY")

        [
          [ CreateEmployeeVerificationItems, "employee_verification_items" ],
          [ CreatePayPeriodVerificationAcknowledgements, "pay_period_verification_acknowledgements" ],
          [ CreateEmployeeReadinessOverrides, "employee_readiness_overrides" ]
        ].each do |migration_class, table_name|
          migration_class.new.send(:stage_company_policy!)
          flags = connection.select_one(
            "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = #{connection.quote(table_name)}::regclass"
          )
          expect(flags).to eq("relrowsecurity" => true, "relforcerowsecurity" => true),
            "Expected #{table_name} to have ENABLE + FORCE RLS when database is enforced"
        end

        raise ActiveRecord::Rollback
      end
    end
  end
end
