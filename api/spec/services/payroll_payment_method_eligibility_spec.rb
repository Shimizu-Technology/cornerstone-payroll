# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollPaymentMethodEligibility do
  let(:company) { create(:company) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:actor) { create(:user, company: company, organization: company.organization) }

  def payment(number)
    create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company), payment_delivery_method: "paper_check",
      check_number: number, net_pay: 500)
  end

  def package(entries)
    period.check_print_runs.create!(company: company, created_by: actor,
      check_stock_type: "standard", storage_key: "synthetic-#{SecureRandom.uuid}",
      filename: "synthetic-checks.pdf", sha256: "a" * 64, byte_size: 100,
      selected_count: entries.size, generated_at: Time.current, manifest: entries)
  end

  it "reuses one period lookup without losing current-number, key, structured, and numberless safeguards" do
    current = payment("8101")
    old_number = payment("8102")
    legacy = payment("8103")
    key_reference = payment("8104")
    noncanonical = payment("8105")
    package([
      { "source_type" => "payroll_item", "source_id" => current.id, "check_number" => "8101" },
      { "source_type" => "payroll_item", "source_id" => old_number.id, "check_number" => "old-8102" },
      { "source_type" => "payroll_item", "source_id" => legacy.id },
      { "source_type" => "non_employee_check", "source_id" => 999, "key" => "payroll_item:#{key_reference.id}", "check_number" => "8104" },
      { "source_type" => "payroll_item", "source_id" => "0#{noncanonical.id}", "check_number" => "8105" }
    ])
    activity = described_class.print_activity_for_period(period)
    rows = period.payroll_items.includes(:check_events, :check_reconciliation_events).to_a
    modes = rows.to_h { |row| [ row.id, described_class.new(row, print_activity: activity).call[:mode] ] }
    expect(modes).to include(current.id => "retire_check", old_number.id => "simple", legacy.id => "retire_check",
      key_reference.id => "retire_check", noncanonical.id => "simple")
    rows.each do |row|
      expect(described_class.new(row, print_activity: activity).call).to eq(described_class.new(row).call)
    end
  end

  it "uses preloaded current and numberless check events without per-item queries" do
    current = payment("8201")
    old_number = payment("8202")
    legacy = payment("8203")
    ignored = payment("8204")
    current.check_events.create!(user: actor, event_type: "printed", check_number: "8201")
    old_number.check_events.create!(user: actor, event_type: "printed", check_number: "old-8202")
    # Append retained legacy evidence directly; current model validation requires
    # a number and the database intentionally forbids editing existing events.
    CheckEvent.insert_all!([ { payroll_item_id: legacy.id, user_id: actor.id,
      event_type: "batch_downloaded", check_number: "", effective_on: PayrollBusinessClock.today,
      created_at: Time.current, updated_at: Time.current } ])
    ignored.check_events.create!(user: actor, event_type: "assigned", check_number: "8204")
    rows = period.payroll_items.includes(:check_events, :check_reconciliation_events).to_a
    queries = []
    modes = nil
    callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      modes = rows.to_h { |row| [ row.id, described_class.new(row, print_activity: {}).call[:mode] ] }
    end
    expect(modes).to include(current.id => "retire_check", old_number.id => "simple", legacy.id => "retire_check", ignored.id => "simple")
    expect(queries.grep(/check_events|check_print_runs|check_reconciliation_events/)).to be_empty
  end
end
