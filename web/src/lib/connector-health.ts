export interface DeliveryHealth {
  recorded_count: number; pending_count: number; failed_count: number;
  last_success_at: string | null; failure_record_updated_at: string | null;
  oldest_pending_at: string | null; oldest_pending_age_seconds: number | null;
  pay_period_ids: number[];
}
export interface ConnectorHealth {
  source_id: number; company_id: number; active: boolean; as_of: string; evidence_scope: 'local_records';
  last_source_activity_at: string | null;
  receipts: { batch: DeliveryHealth; entry: DeliveryHealth };
  calendar: { supported: boolean; recorded_period_count: number; unacknowledged_revision_count: number;
    failed_revision_count: number; last_success_at: string | null; oldest_pending_at: string | null;
    oldest_pending_age_seconds: number | null; pay_period_ids: number[] };
  latest_import_mapping_review: { status: 'not_recorded' | 'unavailable' | 'recorded'; missing_count: number | null; as_of?: string; pay_period_id?: number };
  reconciliation: { pending_classification_count: number; manual_pending_commit_count: number; manual_sync_failed_count: number; pay_period_ids: number[] };
  source_settlement_holds: { status: 'not_fetched'; count: null };
  source_roster_missing_mappings: { status: 'not_fetched'; count: null };
}
