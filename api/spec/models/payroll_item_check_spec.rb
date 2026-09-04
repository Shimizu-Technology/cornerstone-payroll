# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollItem, type: :model do
  let(:company) { create(:company, next_check_number: 5001) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:employee) { create(:employee, company: company) }
  let!(:tax_table) { create(:tax_table) }

  let(:admin_user) do
    User.create!(
      company: company,
      email: "admin-check-test@example.com",
      name: "Check Admin",
      role: "admin",
      active: true
    )
  end

  let(:item) do
    create(:payroll_item, :with_check,
      pay_period: pay_period,
      employee: employee,
      check_number: "5001",
      net_pay: 960.00)
  end

  # ---------------------------------------------------------------------------
  # Check status helper
  # ---------------------------------------------------------------------------
  describe "#check_status" do
    it "returns nil when no check number" do
      item_no_check = create(:payroll_item, pay_period: pay_period, employee: create(:employee, company: company))
      expect(item_no_check.check_status).to be_nil
    end

    it "returns 'unprinted' when check number assigned but not printed" do
      expect(item.check_status).to eq("unprinted")
    end

    it "returns 'printed' when check_printed_at is set" do
      item.update!(check_printed_at: Time.current)
      expect(item.check_status).to eq("printed")
    end

    it "returns 'voided' when voided" do
      item.update!(voided: true)
      expect(item.check_status).to eq("voided")
    end
  end

  # ---------------------------------------------------------------------------
  # mark_printed!
  # ---------------------------------------------------------------------------
  describe "#mark_printed!" do
    it "sets check_printed_at on first call" do
      expect { item.mark_printed!(user: admin_user) }
        .to change { item.reload.check_printed_at }.from(nil)
    end

    it "increments check_print_count" do
      expect { item.mark_printed!(user: admin_user) }
        .to change { item.reload.check_print_count }.by(1)
    end

    it "creates a check_event with type 'printed'" do
      expect { item.mark_printed!(user: admin_user, ip_address: "10.0.0.1") }
        .to change { CheckEvent.where(event_type: "printed").count }.by(1)
    end

    it "records the check number on the event" do
      item.mark_printed!(user: admin_user)
      event = item.check_events.last
      expect(event.check_number).to eq("5001")
    end

    it "does NOT reset check_printed_at on second call (preserves first print timestamp)" do
      item.mark_printed!(user: admin_user)
      first_ts = item.reload.check_printed_at
      item.mark_printed!(user: admin_user)
      expect(item.reload.check_printed_at).to eq(first_ts)
    end

    it "still increments print count on second call" do
      item.mark_printed!(user: admin_user)
      expect { item.mark_printed!(user: admin_user) }
        .to change { item.reload.check_print_count }.by(1)
    end

    it "raises if voided" do
      item.update!(voided: true)
      expect { item.mark_printed!(user: admin_user) }
        .to raise_error(ArgumentError, /voided/)
    end

    it "raises if no check number" do
      item.update_column(:check_number, nil)
      expect { item.mark_printed!(user: admin_user) }
        .to raise_error(ArgumentError, /check number/)
    end
  end

  describe "AIRE entry payment lifecycle" do
    let!(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
    let!(:time_tracking_import) do
      create(
        :time_tracking_import,
        :finalized_aire_batch,
        pay_period: pay_period,
        time_tracking_source: source,
        status: "applied",
        applied_at: Time.current
      )
    end
    let!(:allocation) do
      TimeTrackingEntryAllocation.create!(
        company: company,
        time_tracking_source: source,
        time_tracking_import: time_tracking_import,
        pay_period: pay_period,
        payroll_item: item,
        employee: employee,
        source_user_id: "aire-user-1",
        source_user_uuid: SecureRandom.uuid,
        source_time_entry_id: "1508",
        line_key: "flight:3000",
        source_kind: "current",
        original_work_date: pay_period.start_date,
        category_snapshot: { "name" => "Flight Hours" },
        total_hours: 8,
        regular_hours: 8,
        overtime_hours: 0
      )
    end

    before do
      allocation
      allow(AirePayrollEntryStatusSyncJob).to receive(:perform_later).and_return(true)
    end

    it "distinguishes a prepared check from an issued payment" do
      item.mark_printed!(user: admin_user)

      expect(item.reload.check_status).to eq("printed")
      expect(item.aire_payroll_entry_acknowledgements.pluck(:status, :source_time_entry_id)).to contain_exactly(
        [ "payment_prepared", "1508" ]
      )

      first_delivery = item.mark_delivered!(user: admin_user)
      repeated_delivery = item.mark_delivered!(user: admin_user)

      expect(first_delivery.fetch(:already_delivered)).to be(false)
      expect(repeated_delivery.fetch(:already_delivered)).to be(true)
      expect(item.reload.check_status).to eq("delivered")
      expect(item.check_events.deliveries.count).to eq(1)
      expect(item.aire_payroll_entry_acknowledgements.where(status: "payment_issued").count).to eq(1)
      expect(item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_issued")).to have_attributes(
        payment_method: "paper_check",
        payment_reference: "5001"
      )
    end

    it "records a void after delivery without erasing the earlier payment history" do
      item.mark_printed!(user: admin_user)
      item.mark_delivered!(user: admin_user)
      item.void!(user: admin_user, reason: "Payment was returned and check was voided")

      expect(item.reload.check_status).to eq("voided")
      expect(item.aire_payroll_entry_acknowledgements.pluck(:status)).to contain_exactly(
        "payment_prepared",
        "payment_issued",
        "payment_voided"
      )
    end

    it "rolls back the check action if its durable AIRE outbox record cannot be created" do
      allow(AirePayrollEntryAcknowledgement).to receive(:record_for_check_event!).and_raise(ActiveRecord::RecordInvalid.new)

      expect do
        item.mark_printed!(user: admin_user)
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(item.reload.check_printed_at).to be_nil
      expect(item.check_events.prints).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # void!
  # ---------------------------------------------------------------------------
  describe "#void!" do
    let(:reason) { "Paper jam — physical check destroyed in printer" }

    it "sets voided to true" do
      expect { item.void!(user: admin_user, reason: reason) }
        .to change { item.reload.voided }.from(false).to(true)
    end

    it "sets voided_at" do
      expect { item.void!(user: admin_user, reason: reason) }
        .to change { item.reload.voided_at }.from(nil)
    end

    it "records the voided_by_user_id" do
      item.void!(user: admin_user, reason: reason)
      expect(item.reload.voided_by_user_id).to eq(admin_user.id)
    end

    it "stores the void reason" do
      item.void!(user: admin_user, reason: reason)
      expect(item.reload.void_reason).to eq(reason)
    end

    it "creates a check_event with type 'voided'" do
      expect { item.void!(user: admin_user, reason: reason) }
        .to change { CheckEvent.where(event_type: "voided").count }.by(1)
    end

    it "raises if already voided" do
      item.update!(voided: true)
      expect { item.void!(user: admin_user, reason: reason) }
        .to raise_error(ArgumentError, /Already voided/)
    end

    it "raises if reason is blank" do
      expect { item.void!(user: admin_user, reason: "") }
        .to raise_error(ArgumentError, /Void reason/)
    end

    it "raises if reason is too short (< 10 chars)" do
      expect { item.void!(user: admin_user, reason: "Short") }
        .to raise_error(ArgumentError, /Void reason/)
    end
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------
  describe "scopes" do
    let!(:emp2) { create(:employee, company: company) }
    let!(:item_no_check) { create(:payroll_item, pay_period: pay_period, employee: emp2) }

    it "checks_only returns only non-voided items with check numbers" do
      expect(PayrollItem.checks_only).to include(item)
      expect(PayrollItem.checks_only).not_to include(item_no_check)
    end

    it "voided_checks returns only voided items" do
      item.update!(voided: true)
      expect(PayrollItem.voided_checks).to include(item)
      expect(PayrollItem.voided_checks).not_to include(item_no_check)
    end

    it "unprinted returns non-voided items without a print timestamp" do
      expect(PayrollItem.unprinted).to include(item)
    end

    it "printed returns items with a print timestamp" do
      item.update!(check_printed_at: Time.current)
      expect(PayrollItem.printed).to include(item)
    end
  end

  describe "#calculate!" do
    let(:department) { create(:department, company: company) }
    let(:calc_employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00,
        filing_status: "single"
      )
    end
    let(:calc_pay_period) { create(:pay_period, company: company) }
    let(:calc_item) do
      create(:payroll_item,
        pay_period: calc_pay_period,
        employee: calc_employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40
      )
    end

    it "rolls back deduction and earning clears if save fails" do
      deduction_type = DeductionType.create!(
        company: company,
        name: "Medical Insurance",
        category: "post_tax",
        sub_category: "insurance",
        active: true
      )
      calc_item.payroll_item_deductions.create!(
        deduction_type: deduction_type,
        amount: 15.00,
        category: "post_tax",
        label: "Medical Insurance"
      )
      calc_item.payroll_item_earnings.create!(
        category: "regular",
        label: "Existing Regular Pay",
        hours: 40,
        rate: 20,
        amount: 800
      )

      allow(calc_item).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(calc_item))

      expect { calc_item.calculate! }.to raise_error(ActiveRecord::RecordInvalid)

      calc_item.reload
      expect(calc_item.payroll_item_deductions.pluck(:label)).to include("Medical Insurance")
      expect(calc_item.payroll_item_earnings.pluck(:label)).to include("Existing Regular Pay")
    end
  end
end
