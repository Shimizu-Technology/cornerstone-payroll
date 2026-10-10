-- Read-only pre-release inventory. Run only against an explicitly selected,
-- authorized database or reporting replica; this query performs no backfill.
BEGIN READ ONLY;
SELECT original.company_id, original.pay_period_id AS original_pay_period_id,
       original.id AS original_payroll_item_id, original.employee_id,
       COUNT(*) AS affected_active_corrective_count,
       ARRAY_AGG(correction.id ORDER BY correction.id) AS corrective_item_ids
FROM payroll_items correction
JOIN pay_periods period ON period.id = correction.pay_period_id
JOIN payroll_items original ON original.id = correction.correction_for_payroll_item_id
WHERE correction.voided = FALSE
  AND period.status = 'committed'
  AND (period.correction_status IS NULL OR period.correction_status = 'correction')
  AND (COALESCE(jsonb_typeof(correction.calculation_context_snapshot->'corrective_paycheck'), 'null') <> 'object'
       OR correction.calculation_context_snapshot->'corrective_paycheck'->'version' IS DISTINCT FROM '1'::jsonb
       OR COALESCE(jsonb_typeof(correction.calculation_context_snapshot->'corrective_paycheck'->'input_adjustments'), 'null') <> 'object')
GROUP BY original.company_id, original.pay_period_id, original.id, original.employee_id
ORDER BY original.company_id, original.pay_period_id, original.id;
ROLLBACK;
