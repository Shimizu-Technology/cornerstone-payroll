# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollSubmissions::Serializer do
  let(:company) { create(:company) }
  let(:staff) { create(:user, company: company, role: "manager") }

  def add_period(index)
    starts = Date.new(2026, 10, 1) + index * 7
    run = create(:pay_period, company: company, start_date: starts, end_date: starts + 6, pay_date: starts + 10)
    PayrollSubmissionPeriod.create!(company: company, pay_period: run, start_date: run.start_date,
      end_date: run.end_date, pay_date: run.pay_date, source: "pay_period", status: "paid")
  end

  def list_query_count
    catalog = PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 17))
    entries = catalog.entries
    serializer = described_class.new(current_user: staff, catalog: catalog)
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      expect(serializer.summaries(entries).size).to eq(entries.size)
      entries.each { |entry| serializer.allowed_actions(entry) }
    end
    queries.reject { |sql| sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/) }.size
  end

  it "batches live runs and published reviews and reuses the live run for actions" do
    2.times { |index| add_period(index) }
    list_query_count # warm schema metadata
    small = list_query_count
    4.times { |index| add_period(index + 2) }
    expect(list_query_count - small).to be <= 1
  end
end
