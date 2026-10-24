require 'rails_helper'

RSpec.describe 'Independent next-cutoff and legacy probes' do
  before do
    allow(AirePayrollEvent).to receive(:dispatch_one!)
  end
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: 'aire_services', shared_secret: 'review-synthetic-388') }
  let(:period) { create(:pay_period, company: company, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15') }
  let(:calendar) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period) }

  def receive_batch(publication, batch)
    payload = build_aire_finalized_event(calendar_period: calendar, publication: publication, batch_payload: batch)
    AirePayrollEvents::Receiver.new(payload: payload, shared_secret: 'review-synthetic-388', idempotency_key: payload.fetch('event_id')).call
  end

  it 'clears the next scheduled cutoff when the only scheduled publication has finalized' do
    uuid = SecureRandom.uuid
    publication = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, delivery_status: 'delivered', publication_id: uuid,
      source_state: { 'next_scheduled_cutoff_at' => '2026-11-07T17:00:00+10:00' },
      payload: { 'schema_version'=>'2.0', 'start_date'=>'2026-10-16', 'end_date'=>'2026-10-31', 'pay_date'=>'2026-11-15',
        'cutoff_at'=>'2026-11-07T17:00:00+10:00', 'schedule_version'=>1, 'publication_id'=>uuid,
        'lock_mode'=>'scheduled', 'cutoff_enforcement_starts_on'=>'2026-10-16' })
    batch = build_aire_batch_payload(start_date: '2026-10-16', end_date: '2026-10-31', cutoff_at: '2026-11-07T17:00:00+10:00')
    receive_batch(publication, batch).event.update!(verification_status: 'verified', verified_at: Time.current)
    state = AirePayrollCalendar::Presenter.call(period, now: Time.iso8601('2026-11-08T12:00:00+10:00'))
    puts "NEXT_FINALIZED=#{state.slice(:cutoff_state, :next_scheduled_cutoff_at).to_json}"
    expect(state[:next_scheduled_cutoff_at]).to be_nil
  end

  it 'refuses rollout configuration and a manual callback for a legacy-wire publication' do
    period.update!(start_date: '2026-10-01', end_date: '2026-10-15', pay_date: '2026-10-31')
    uuid = SecureRandom.uuid
    publication = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, delivery_status: 'delivered', publication_id: uuid,
      payload: { 'schema_version'=>'2.0', 'start_date'=>'2026-10-01', 'end_date'=>'2026-10-15', 'pay_date'=>'2026-10-31',
        'cutoff_at'=>'2026-10-22T17:00:00+10:00', 'schedule_version'=>1, 'publication_id'=>uuid })
    batch = build_aire_batch_payload(cutoff_at: '2026-10-25T12:00:00.123456+10:00')
    payload = build_aire_finalized_event(calendar_period: calendar, publication: publication, batch_payload: batch)
    payload['payroll_period'].merge!('lock_mode'=>'manual', 'cutoff_enforcement_starts_on'=>'2026-10-16', 'locked_at'=>batch['cutoff_at'])
    expect {
      AirePayrollCalendar::LockRollout.new(source: source, starts_on: "2026-10-16", actor: "Test operator", reason: "Rollout gate").configure!
    }.to raise_error(AirePayrollCalendar::LockRollout::Error, /lacks explicit manual/)
    expect { AirePayrollEvents::Receiver.new(payload: payload, shared_secret: 'review-synthetic-388', idempotency_key: payload.fetch('event_id')).call }
      .to raise_error(AirePayrollEvents::Receiver::ConflictError, /does not match/)
    expect(AirePayrollEvent.count).to eq(0)
  end
end
