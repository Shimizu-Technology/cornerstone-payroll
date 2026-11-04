# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::HistoricalRoundingReview do
  it "keeps bindings and signed acknowledgements separate for two unsaved proposed person mappings" do
    company = create(:company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services", expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0", identity_verified_at: Time.current)
    actor = create(:user, company: company)
    run = create(:pay_period, :committed, company: company)
    categories = [ { "key" => "flight", "name" => "Flight" }, { "key" => "ground", "name" => "Ground" } ]
    batch = { "batch_id" => "SHARED-BATCH", "export" => { "checksum" => "b" * 64 } }
    people = 2.times.map do |index|
      employee = create(:employee, company: company)
      mapping = TimeTrackingEmployeeMapping.new(company: company, time_tracking_source: source, employee: employee,
        source_user_id: (91 + index).to_s, source_user_uuid: SecureRandom.uuid)
      ids = [ 100 + index * 10, 101 + index * 10 ]
      item = create(:payroll_item, company: company, employee: employee, pay_period: run, hours_worked: 6.13, overtime_hours: 0,
        custom_columns_data: { "wage_rate_hours" => ids.each_with_index.map { |id, offset|
          { "employee_wage_rate_id" => id, "label" => categories[offset]["name"], "active" => true, "regular_hours" => offset.zero? ? 3.1 : 3.03, "overtime_hours" => 0 }
        } })
      lines = categories.each_with_index.map { |category, offset| { "category" => category, "total_hours" => offset.zero? ? "3.1" : "3.0", "regular_hours" => offset.zero? ? "3.1" : "3.0", "overtime_hours" => "0" } }
      { args: { batch: batch, run: run, mapping: mapping, source_employee: { "adjustments" => lines }, items: [ item ], source_inventory_checksum: "i" * 64, run_checksum: "r" * 64 }, rates: ids }
    end
    review = { "reviewer_id" => actor.id, "reason" => "Reviewed separate proposed employee dimensions", "evidence" => "Synthetic two-person frozen source and committed register" }
    discovery = described_class.new(source: source, actor: actor)
    people.each { |person| discovery.verify!(**person[:args], discover: true) }
    bindings = discovery.blockers.map do |row|
      person = people.find { |candidate| candidate[:args][:mapping].source_user_uuid == row["source_user_uuid"] }
      offset = categories.index(row["source_category"])
      row.except("reason").merge(review, "type" => "historical_earning_component_binding", "earning_component" => "wage_rate:#{person[:rates][offset]}")
    end
    discovery = described_class.new(source: source, actor: actor, component_bindings: bindings)
    people.each { |person| discovery.verify!(**person[:args], discover: true) }
    expect(discovery.table.size).to eq(2)
    acknowledgements = discovery.table.map { |row| row.except("within_limit", "acknowledged").merge(review, "type" => "accountant_reviewed_rounding_variance") }
    verifier = described_class.new(source: source, actor: actor, component_bindings: bindings, acknowledgements: acknowledgements)
    people.each { |person| expect(verifier.verify!(**person[:args])).to be(true) }
    expect(verifier.acknowledgements_valid?).to be(true)
    expect(verifier.table.map { |row| row["source_user_uuid"] }.uniq.size).to eq(2)
    wrong_person = acknowledgements.deep_dup
    wrong_person.first["source_user_uuid"] = wrong_person.last["source_user_uuid"]
    invalid = described_class.new(source: source, actor: actor, component_bindings: bindings, acknowledgements: wrong_person)
    expect(invalid.verify!(**people.first[:args])).to be(false)
  end
end
