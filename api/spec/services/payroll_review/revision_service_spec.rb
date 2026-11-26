# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollReview::RevisionService do
  let!(:organization) { create(:organization, name: "Revision Review Firm") }
  let!(:company) { create(:company, organization: organization, client_payroll_approval_required: true) }
  let!(:staff) { create(:user, company: company, organization: organization, role: "manager", active: true) }
  let!(:client) { create(:user, company: company, organization: organization, role: "client", active: true) }
  let!(:other_client) { create(:user, company: create(:company), role: "client", active: true) }
  let!(:employee) { create(:employee, company: company) }
  let!(:pay_period) { create(:pay_period, company: company, status: "calculated", calculated_at: Time.current) }
  let!(:payroll_item) do
    create(:payroll_item, company: company, pay_period: pay_period, employee: employee,
                          hours_worked: 80, gross_pay: 1_600, total_deductions: 250, net_pay: 1_350)
  end

  before do
    ensure_verified_test_tax_years(2024, 2026)
    CompanyAssignment.create!(user: client, company: company)
  end

  subject(:service) { described_class.new(pay_period: pay_period, actor: staff) }

  it "recovers a failed publication notification on republish without duplicating events" do
    allow(PortalNotifications).to receive(:record!).and_wrap_original do |original, **args|
      original.call(**args)
      raise ActiveRecord::StatementInvalid, "notification failure"
    end

    PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff).approve!
    package = pay_period.payroll_review_packages.current.first!
    expect(pay_period.reload).to be_approved
    expect(package.published_at).to be_present
    events = PortalNotificationEvent.where(dedupe_key: "payroll_review_published:#{package.id}")
    expect(events).to be_empty

    allow(PortalNotifications).to receive(:record!).and_call_original
    expect(service.publish!).to eq(package)
    expect(service.publish!).to eq(package)
    expect(events.count).to eq(1)
    expect(events.first.event_type).to eq("payroll_review_published")
    expect(AuditLog.where(action: "payroll_review#published", record_id: package.id).count).to eq(1)
  end

  it "issues an immutable checksum revision and reuses it while payroll is unchanged" do
    first = service.issue!
    second = service.issue!

    expect(second).to eq(first)
    expect(first).to have_attributes(revision: 1, status: "pending", company_id: company.id)
    expect(first.client_review_history_unknown?).to be(false)
    expect(first.calculation_checksum).to match(/\A[0-9a-f]{64}\z/)
    expect(first.calculation_snapshot.dig("payroll_items", 0, "employee_id")).to eq(employee.id)
    expect(first.calculation_snapshot.dig("payroll_items", 0, "employee")).to include(
      "id" => employee.id,
      "first_name" => employee.first_name,
      "last_name" => employee.last_name
    )
  end

  it "keeps the existing payroll review revision valid when child company ownership is backfilled" do
    type = DeductionType.create!(company: company, name: "Test deduction", category: "post_tax")
    deduction = payroll_item.payroll_item_deductions.create!(
      deduction_type: type, category: "post_tax", label: "Test deduction", amount: 20
    )
    # Legacy rows predate the contract migration that requires company_id.
    ActiveRecord::Base.connection.change_column_null :payroll_item_deductions, :company_id, true
    deduction.update_column(:company_id, nil)
    revision = service.issue!
    snapshot = revision.calculation_snapshot.dig("payroll_items", 0, "payroll_item_deductions", 0)
    expect(snapshot).not_to have_key("company_id")

    PayrollChildCompanyBackfill.new(connection: ApplicationRecord.connection).backfill { |_, _| }
    expect(deduction.reload.company_id).to eq(company.id)
    expect(service.issue!).to eq(revision)
  end

  it "locks company before period and keeps calculation separate from publication" do
    company.update!(client_payroll_approval_required: false)
    pay_period.company # cache the disabled setting on this instance
    Company.find(company.id).update!(client_payroll_approval_required: true)
    locks = []
    subscriber = ->(_name, _start, _finish, _id, payload) { locks << payload[:sql] if payload[:sql].include?("FOR UPDATE") }
    package = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { service.issue! }
    expect(package.sent_for_client_approval_at).to be_nil
    company_lock = locks.index { |sql| sql.include?('"companies"') }
    period_lock = locks.index { |sql| sql.include?('"pay_periods"') }
    expect(company_lock).to be < period_lock
  end

  it "stamps a visible legacy revision before disabling approval" do
    package = service.issue!
    package.update_columns(sent_for_client_approval_at: nil)
    company.update!(client_payroll_approval_required: false)
    expect(package.reload.sent_for_client_approval_at).to be_present
    expect(pay_period.reload.deletion_blocker).to include("client review history")
  end

  it "does not call an invisible superseded draft revision shared when approval is enabled" do
    company.update!(client_payroll_approval_required: false)
    package = service.issue!
    pay_period.invalidate_calculation!(reason: "Inputs changed before client review")
    company.update!(client_payroll_approval_required: true)
    expect(package.reload.sent_for_client_approval_at).to be_nil
    expect(package.client_review_history_unknown?).to be(false)
    expect(package.retained_client_evidence?).to be(false)
    expect { pay_period.reload.destroy! }.not_to raise_error
    expect(PayPeriod.exists?(pay_period.id)).to be(false)
    expect(PayrollReviewPackage.exists?(package.id)).to be(false)
  end

  it "creates a new review revision when the displayed employee identity changes" do
    first = service.issue!
    employee.update!(last_name: "Corrected")

    second = service.issue!

    expect(second).to have_attributes(revision: 2, status: "pending")
    expect(second.calculation_checksum).not_to eq(first.calculation_checksum)
    expect(second.calculation_snapshot.dig("payroll_items", 0, "employee", "last_name")).to eq("Corrected")
  end

  it "supersedes an approved revision and creates a new pending revision when payroll changes" do
    first = service.issue!
    pay_period.update!(status: "approved")
    service.publish!
    service.approve!(
      approver: client,
      recorded_by: client,
      method: "client_portal", revision_id: pay_period.payroll_review_packages.current.first.id,
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
    )
    payroll_item.update!(hours_worked: 81, gross_pay: 1_620, net_pay: 1_370)

    pay_period.update!(status: "calculated")
    second = service.issue!

    expect(first.reload).to have_attributes(status: "superseded", superseded_at: be_present)
    expect(first.approved_by).to eq(client)
    expect(second).to have_attributes(revision: 2, status: "pending")
    expect(second.calculation_checksum).not_to eq(first.calculation_checksum)
  end

  it "requires an exact approval statement from an assigned client user" do
    service.issue!

    expect do
      pay_period.update!(status: "approved")
    service.publish!
    service.approve!(approver: client, recorded_by: client, method: "client_portal", revision_id: pay_period.payroll_review_packages.current.first.id, acknowledgement: "Received, thank you!")
    end.to raise_error(described_class::Error, /exact payroll revision/)

    expect do
      pay_period.update!(status: "approved")
    service.publish!
    service.approve!(approver: other_client, recorded_by: other_client, method: "client_portal", revision_id: pay_period.payroll_review_packages.current.first.id,
                       acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT)
    end.to raise_error(described_class::Error, /assigned to this client/)
  end

  it "requires retained evidence when staff records an email attestation" do
    staff.update!(role: "org_admin")
    service.issue!

    expect do
      pay_period.update!(status: "approved")
    service.publish!
    service.approve!(
        approver: client,
        recorded_by: staff,
        method: "email_attestation", revision_id: pay_period.payroll_review_packages.current.first.id,
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      )
    end.to raise_error(described_class::Error, /message reference/)

    approved = service.approve!(
      approver: client,
      recorded_by: staff,
      method: "email_attestation", revision_id: pay_period.payroll_review_packages.current.first.id,
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT,
      evidence_reference: "gmail-message-123"
    )
    expect(approved).to have_attributes(
      status: "approved",
      approved_by: client,
      approval_recorded_by: staff,
      approval_evidence_reference: "gmail-message-123"
    )
  end

  it "keeps saved revision identity and approval evidence immutable" do
    review_package = service.issue!
    pay_period.update!(status: "approved")
    service.publish!
    service.approve!(
      approver: client,
      recorded_by: client,
      method: "client_portal", revision_id: pay_period.payroll_review_packages.current.first.id,
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT,
      notes: "Approved as shown"
    )
    review_package.reload

    expect { review_package.update!(calculation_checksum: "f" * 64) }
      .to raise_error(ActiveRecord::RecordInvalid, /revision identity cannot be changed/)
    review_package.reload
    expect { review_package.update!(approval_notes: "Changed after approval") }
      .to raise_error(ActiveRecord::RecordInvalid, /approval evidence cannot be changed/)
    review_package.reload
    expect { review_package.update!(status: "pending", approved_at: nil, approved_by: nil) }
      .to raise_error(ActiveRecord::RecordInvalid, /cannot transition from approved/)
  end

  it "blocks commit when client approval is missing or the calculation changed" do
    review_package = service.issue!
    expect { service.verify_required_approval! }.to raise_error(described_class::Error, /still required/)

    pay_period.update!(status: "approved")
    service.publish!
    service.approve!(
      approver: client,
      recorded_by: client,
      method: "client_portal", revision_id: pay_period.payroll_review_packages.current.first.id,
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
    )
    expect(service.verify_required_approval!).to be(true)

    payroll_item.update!(net_pay: payroll_item.net_pay + 1)
    expect { service.verify_required_approval! }.to raise_error(described_class::Error, /changed after client review revision/)
    expect(review_package.reload).to be_approved
  end
  def client_decision(package)
    service.approve!(approver: client, recorded_by: client, method: "client_portal", revision_id: package.id,
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT)
  end

  it "refuses a Client viewer as the approver, including an email attestation staff record for them" do
    viewer = create(:user, company: company, organization: organization, role: "client", active: true, client_access_level: "viewer")
    CompanyAssignment.create!(user: viewer, company: company)
    PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff).approve!
    package = pay_period.payroll_review_packages.current.first!

    expect do
      service.approve!(approver: viewer, recorded_by: staff, method: "email_attestation", revision_id: package.id,
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT, evidence_reference: "message-ref-1")
    end.to raise_error(described_class::Error, described_class::VIEWER_CANNOT_DECIDE)
    expect do
      described_class.new(pay_period: pay_period, actor: viewer).approve!(approver: viewer, recorded_by: viewer,
        method: "client_portal", revision_id: package.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT)
    end.to raise_error(described_class::Error, described_class::VIEWER_CANNOT_DECIDE)
    expect do
      described_class.new(pay_period: pay_period, actor: viewer).request_changes!(revision_id: package.id, note: "Correct hours")
    end.to raise_error(described_class::Error, described_class::VIEWER_CANNOT_DECIDE)
    expect(package.reload).to have_attributes(status: "pending", approved_by_id: nil, changes_requested_at: nil)
    expect(described_class.client_can_decide?(package, viewer)).to be(false)
  end

  it "publishes at staff approval and accepts the current client decision before commit" do
    package = service.issue!
    lifecycle = PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff)
    lifecycle.approve!
    expect(package.reload.published_at).to be_present
    expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Client approval is still required/)
    client_decision(package)
    lifecycle.commit!
    expect(pay_period.reload).to be_committed
  end

  it "rejects a change request from the client who prepared the preview" do
    client_service = described_class.new(pay_period: pay_period, actor: client)
    package = client_service.issue!
    PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff).approve!

    expect { client_service.request_changes!(revision_id: package.id, note: "Correct hours") }
      .to raise_error(described_class::Error, /cannot decide a payroll preview you prepared/)
    expect(package.reload.changes_requested_at).to be_nil
  end

  describe ".client_can_decide?" do
    let(:package) do
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff).approve!
      pay_period.payroll_review_packages.current.first!
    end

    it "withholds decision access from view-as viewers" do
      expect(described_class.client_can_decide?(package, client)).to be(true)
      Current.set(view_as_grant: ViewAsGrant.new) do
        expect(described_class.client_can_decide?(package, client)).to be(false)
      end
    end

    it "withholds decision access from staff and inactive clients" do
      expect(described_class.client_can_decide?(package, staff)).to be(false)
      client.update!(active: false)
      expect(described_class.client_can_decide?(package, client)).to be(false)
    end
  end

  it "retains a requested change and requires a newly published revision after unapprove and recalculate" do
    lifecycle = PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff)
    lifecycle.approve!
    package = pay_period.payroll_review_packages.current.first!
    client_service = described_class.new(pay_period: pay_period, actor: client)
    expect { client_service.request_changes!(revision_id: package.id, note: " ") }.to raise_error(described_class::Error, /Describe/)
    client_service.request_changes!(revision_id: package.id, note: "Correct hours")
    lifecycle.unapprove!
    expect(package.reload).to have_attributes(status: "superseded", changes_requested_by: client, change_request_note: "Correct hours")
    payroll_item.update!(hours_worked: 82)
    next_package = service.issue!
    lifecycle.approve!
    expect { client_decision(package) }.to raise_error(described_class::Error, /revision changed/)
    client_decision(next_package)
    lifecycle.commit!
    expect(pay_period.reload).to be_committed
  end

  it "withdraws approved evidence on unapprove and allows commit without a client gate when disabled" do
    lifecycle = PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff)
    lifecycle.approve!
    package = pay_period.payroll_review_packages.current.first!
    client_decision(package)
    lifecycle.unapprove!
    expect(package.reload).to have_attributes(status: "superseded", approved_by: client)
    expect { service.verify_required_approval! }.to raise_error(described_class::Error, /before commit/)
    lifecycle.approve!
    expect(pay_period.payroll_review_packages.current.first.revision).to eq(2)
    company.update!(client_payroll_approval_required: false)
    lifecycle.commit!
    expect(pay_period.reload).to be_committed
  end

  it "retains a pre-rollout calculated-run approval as history and requires a published decision" do
    pay_period.update!(status: "approved")
    package = service.publish!
    client_decision(package)
    package.update_columns(published_at: nil)
    pay_period.update!(status: "calculated")
    PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff).approve!
    current = pay_period.payroll_review_packages.current.first!
    expect(package.reload).to have_attributes(status: "superseded", approved_by: client)
    expect(current).to have_attributes(revision: 2, status: "pending", published_at: be_present)
  end
  describe "#override!" do
    let(:reason) { "Client asked Cornerstone to approve this revision." }
    let(:arguments) do
      { revision_id: package.id, acknowledgement: PayrollReviewPackage::OVERRIDE_ACKNOWLEDGEMENT, override_reason: reason }
    end
    let!(:package) do
      service.issue!
      pay_period.update!(status: "approved", approved_by_id: staff.id)
      service.publish!
    end

    User.roles.each_key do |role|
      it "enforces the override capability for #{role}" do
        staff.update!(role: role)
        if %w[super_admin org_admin admin].include?(role)
          expect(service.override!(**arguments)).to have_attributes(
            approval_method: "cornerstone_override", override_reason: reason, self_override: true, approved_by: staff
          )
          expect(AuditLog.find_by!(action: "payroll_review#overridden", record_id: package.id).metadata).to include(
            "revision" => package.revision, "checksum" => package.calculation_checksum, "override_reason" => reason,
            "self_override" => true, "method" => "cornerstone_override"
          )
        else
          expect { service.override!(**arguments) }.to raise_error(described_class::Error, /Admin access/)
          expect(package.reload).to be_pending
        end
      end
    end

    context "as an administrator" do
      before { staff.update!(role: "org_admin") }

      it "refuses an impersonated session" do
        allow(Current).to receive(:view_as_grant).and_return(true)
        expect { service.override!(**arguments) }.to raise_error(described_class::Error, /Exit Sign in as/)
      end

      it "checks the persisted role for both staff-recorded decisions" do
        User.where(id: staff.id).update_all(role: User.roles.fetch("manager"))
        expect { service.override!(**arguments) }.to raise_error(described_class::Error, /Admin access/)
        expect do
          service.approve!(approver: client, recorded_by: staff, method: "email_attestation", revision_id: package.id,
            acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT, evidence_reference: "Stored approval email")
        end.to raise_error(described_class::Error, /Admin access/)
        expect(package.reload).to be_pending
      end

      it "rejects a missing or short reason" do
        [ nil, "short" ].each do |reason|
          expect { service.override!(**arguments.merge(override_reason: reason)) }.to raise_error(described_class::Error, /10–500/)
        end
        expect(package.reload).to be_pending
      end

      it "refuses changed calculation evidence" do
        payroll_item.update!(gross_pay: 2_000)
        expect { service.override!(**arguments) }.to raise_error(described_class::StaleRevisionError)
      end

      it "preserves a pending revision if the audit write fails" do
        allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
        expect { service.override!(**arguments) }.to raise_error(described_class::Error)
        expect(package.reload).to be_pending
      end
    end
  end
end
