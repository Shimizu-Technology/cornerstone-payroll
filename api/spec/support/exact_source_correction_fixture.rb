# frozen_string_literal: true

RSpec.shared_context "exact source correction fixtures" do
  let!(:tax_table) { create(:tax_table, tax_year: 2026) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: 'admin') }
  let(:employee) { create(:employee, company: company, pay_rate: 25, pay_frequency: 'biweekly', filing_status: 'single', allowances: 0) }
  let(:instance_id) { SecureRandom.uuid }
  let(:user_uuid) { SecureRandom.uuid }
  let!(:rate) { create(:employee_wage_rate, employee: employee, rate: 25, label: 'Flight Hours', is_primary: true) }
  let!(:workweek) { CompanyWorkweek.create!(company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: 'Pacific/Guam', effective_on: '2026-01-01', confirmation_status: 'confirmed', confirmed_by: actor, notes: 'Verified test workweek', confirmed_at: Time.current) }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: 'custom',
      remote_source_identifier: 'fixture_time', expected_source_instance_id: instance_id,
      source_protocol: 'shimizu_time_payroll', source_protocol_version: '1.0',
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2], identity_verified_at: Time.current)
  end
  let(:original_period) { create(:pay_period, company: company, start_date: '2026-10-01', end_date: '2026-10-15', pay_date: '2026-10-30') }
  let(:next_period) { create(:pay_period, company: company, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15') }
  let(:original_payment_state) { "delivered" }
  let(:original_wage_rate_hours) { [] }
  let(:original_regular_hours) { 4 }
  let(:original_overtime_hours) { 0 }
  let(:original_item) do
    item = create(:payroll_item, company: company, employee: employee, pay_period: original_period,
      pay_rate: 25, hours_worked: original_regular_hours, overtime_hours: original_overtime_hours, holiday_hours: 0, pto_hours: 0,
      wage_rate_hours: original_wage_rate_hours)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    original_period.update!(status: 'committed', committed_at: Time.current)
    employee.ytd_totals_for(2026).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2026).add_payroll_item!(item)
    item.update!(payment_delivery_method: "direct_deposit") if original_payment_state.start_with?("direct_deposit")
    company.assign_check_numbers!([ item ]) unless original_payment_state.start_with?("direct_deposit")
    item.reload
    if original_payment_state == "delivered" || original_payment_state == "voided_payment"
      item.update!(check_printed_at: Time.current)
      item.mark_delivered!(user: actor, delivered_on: PayrollBusinessClock.today, delivery_method: "hand_delivery",
        attestation: true, evidence_reference: "Synthetic verified original delivery")
      if original_payment_state == "voided_payment"
        item.check_events.create!(user: actor, event_type: "voided", check_number: item.check_number,
          details: { payment_delivery_change: true, confirmed_not_paid: true, original_check_cancelled: true, payroll_obligation_retained: true })
      end
    elsif original_payment_state == "prepared"
      item.update!(check_printed_at: Time.current)
      item.check_events.create!(user: actor, event_type: "printed", check_number: item.check_number)
    elsif original_payment_state == "direct_deposit_confirmed"
      item.create_direct_deposit_payment_confirmation!(user: actor, settled_on: PayrollBusinessClock.today,
        bank_reference: "SYNTHETIC-BANK-CONFIRMED")
    end
    item.reload
  end
  let(:original_import) { make_import(original_period, 4, 'current', 'ORIGINAL', status: 'applied') }
  let(:next_import) { make_import(next_period, -1, 'correction', 'NEXT') }
  let!(:allocation) do
    source
    item = original_item
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee, source_user_id: '42', source_user_uuid: user_uuid)
    TimeTracking::EntryAllocationRecorder.new(time_tracking_import: original_import, payroll_item: item,
      source_employee: original_import.raw_payload['employees'].first).call
    original_import.time_tracking_entry_allocations.first
  end
  let(:service) { TimeTracking::ExactLineCorrectionService.new(import: next_import, actor: actor, source_user_id: '42', source_time_entry_id: '101', line_key: '7:2500') }

  before do
    allow_any_instance_of(TimeTracking::Client).to receive(:payroll_batch) { |_client, batch_id:| batch_id == 'NEXT' ? next_import.raw_payload : original_import.raw_payload }
  end

  def make_import(period, hours, kind, batch_id, status: 'previewed', mixed: false, entry_version: nil, daily_lines: nil, category_name: nil)
    raw = build_aire_batch_payload(batch_id: batch_id, start_date: period.start_date.iso8601, end_date: period.end_date.iso8601)
    raw['source'] = 'fixture_time'
    raw['integration'] = { 'protocol' => 'shimizu_time_payroll', 'protocol_version' => '1.0',
      'source_instance_id' => instance_id, 'source_type' => 'fixture_time', 'capabilities' => %w[finalized_batch_v2 exact_line_receipts_v2] }
    raw['exclusions'] = []
    row = raw['employees'].first
    row['source_user_uuid'] = user_uuid
    line = row['adjustments'].first
    line['source_user_uuid'] = user_uuid
    line['source_kind'] = kind
    line['source_time_entry_version'] = entry_version || (kind == 'current' ? 0 : 1)
    %w[total_hours regular_hours].each { |key| row[key] = hours; line[key] = hours; raw['summary'][key] = hours }
    raw['summary']['exclusion_count'] = 0
    raw['summary']['current_count'] = kind == 'current' ? 1 : 0
    raw['summary']['correction_count'] = kind == 'correction' ? 1 : 0
    raw['issues']['pending_approval_count'] = 0
    raw['issues']['negative_adjustment_count'] = hours.negative? ? 1 : 0
    if mixed
      2.times do |index|
        worker = create(:employee, company: company, pay_rate: 25)
        create(:employee_wage_rate, employee: worker, rate: 25, label: "Flight Hours", is_primary: true)
        uuid = SecureRandom.uuid
        id = (50 + index).to_s
        TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: worker, source_user_id: id, source_user_uuid: uuid)
        positive = row.deep_dup
        positive["source_user_id"] = id
        positive["source_user_uuid"] = uuid
        positive["email"] = worker.email
        positive["display_name"] = worker.full_name
        positive_line = positive["adjustments"].first
        positive_line["source_time_entry_id"] = (200 + index).to_s
        positive_line["source_user_uuid"] = uuid
        positive_line["source_kind"] = "carryover"
        %w[total_hours regular_hours].each { |key| positive[key] = 4; positive_line[key] = 4 }
        raw["employees"] << positive
      end
      raw["summary"].merge!("employee_count" => 3, "adjustment_count" => 3, "carryover_count" => 2, "total_hours" => 7, "regular_hours" => 7)
    end
    line["category"]["name"] = category_name if category_name
    if daily_lines
      row["adjustments"] = daily_lines.map do |attributes|
        line.deep_dup.deep_merge(attributes.deep_stringify_keys)
      end
      %w[total_hours regular_hours overtime_hours].each do |key|
        row[key] = row["adjustments"].sum { |entry| entry[key].to_d }.to_f
        raw["summary"][key] = row[key]
      end
      raw["summary"]["adjustment_count"] = row["adjustments"].length
      %w[current carryover correction].each do |source_kind|
        raw["summary"]["#{source_kind}_count"] = row["adjustments"].count { |entry| entry["source_kind"] == source_kind }
      end
      raw["issues"]["negative_adjustment_count"] = row["adjustments"].count { |entry| entry["regular_hours"].to_d.negative? || entry["overtime_hours"].to_d.negative? }
    end
    raw['export']['checksum'] = TimeTracking::CanonicalPayload.checksum(raw.except('export'))
    processed = TimeTracking::BatchImportPreviewService.new(pay_period: period, source: source).send(:process, raw, workweek: workweek)
    create(:time_tracking_import, pay_period: period, time_tracking_source: source, status: status,
      external_batch_id: batch_id, external_batch_checksum: raw['export']['checksum'],
      source_payload_hash: raw['export']['checksum'], contract_version: '2.0', source_cutoff_at: Time.iso8601(raw['cutoff_at']),
      raw_payload: raw, processed_payload: processed)
  end

  def confirm(preview = service.preview, **options)
    service.confirm!(**{ preview_token: preview[:preview_token], reason: 'Source hours corrected by operator', acknowledge_accounting_only: true }.merge(options))
  end
end
