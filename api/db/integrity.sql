-- Current database guards omitted by Rails Ruby schema dumps.
-- Definitions retain migration order so later function replacements win.
-- Install transactionally after schema load; ordinary migrations remain authoritative for upgrades.

-- 20260717120000_protect_platform_owner_and_enrich_audit_history.rb
CREATE OR REPLACE FUNCTION prevent_primary_platform_owner_delete()
RETURNS trigger AS $$
BEGIN
  IF OLD.platform_owner = TRUE THEN
    RAISE EXCEPTION 'The primary platform owner cannot be deleted';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protect_primary_platform_owner_delete ON users;
CREATE TRIGGER protect_primary_platform_owner_delete
BEFORE DELETE ON users
FOR EACH ROW
EXECUTE FUNCTION prevent_primary_platform_owner_delete();

-- 20260908120000_create_payroll_go_live_reviews.rb
CREATE OR REPLACE FUNCTION prevent_pay_period_parallel_run_clear()
RETURNS trigger AS $$
BEGIN
  IF OLD.parallel_run = TRUE AND NEW.parallel_run = FALSE THEN
    RAISE EXCEPTION 'parallel_run cannot be cleared after a payroll is used for comparison'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS pay_periods_parallel_run_immutable ON pay_periods;
CREATE TRIGGER pay_periods_parallel_run_immutable
BEFORE UPDATE OF parallel_run ON pay_periods
FOR EACH ROW
EXECUTE FUNCTION prevent_pay_period_parallel_run_clear();

-- 20260913080000_create_employee_document_requirements.rb
CREATE OR REPLACE FUNCTION prevent_employee_document_requirement_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  RAISE EXCEPTION 'employee_document_requirement_events are append-only'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$function$;

DROP TRIGGER IF EXISTS employee_document_requirement_events_append_only ON employee_document_requirement_events;
CREATE TRIGGER employee_document_requirement_events_append_only
BEFORE UPDATE OR DELETE ON employee_document_requirement_events
FOR EACH ROW
EXECUTE FUNCTION prevent_employee_document_requirement_event_mutation();

-- 20260914040000_create_check_reconciliation_events.rb
CREATE OR REPLACE FUNCTION prevent_check_evidence_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION '% records are append-only', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_events_append_only ON check_events;
CREATE TRIGGER check_events_append_only
BEFORE UPDATE OR DELETE ON check_events
FOR EACH ROW EXECUTE FUNCTION prevent_check_evidence_mutation();

DROP TRIGGER IF EXISTS check_reconciliation_events_append_only ON check_reconciliation_events;
CREATE TRIGGER check_reconciliation_events_append_only
BEFORE UPDATE OR DELETE ON check_reconciliation_events
FOR EACH ROW EXECUTE FUNCTION prevent_check_evidence_mutation();

-- 20260914050000_create_payroll_filing_records.rb
CREATE OR REPLACE FUNCTION prevent_payroll_filing_event_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'payroll_filing_events are append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS payroll_filing_events_append_only ON payroll_filing_events;
CREATE TRIGGER payroll_filing_events_append_only
BEFORE UPDATE OR DELETE ON payroll_filing_events
FOR EACH ROW EXECUTE FUNCTION prevent_payroll_filing_event_mutation();

-- 20260914060000_add_certification_evidence_to_employee_reviews.rb
CREATE OR REPLACE FUNCTION prevent_employee_configuration_review_resolution_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'employee_configuration_review_resolutions are append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS employee_configuration_review_resolutions_append_only ON employee_configuration_review_resolutions;
CREATE TRIGGER employee_configuration_review_resolutions_append_only
BEFORE UPDATE OR DELETE ON employee_configuration_review_resolutions
FOR EACH ROW EXECUTE FUNCTION prevent_employee_configuration_review_resolution_mutation();

-- 20260928010000_create_payroll_item_legacy_dispositions.rb
CREATE OR REPLACE FUNCTION prevent_payroll_item_legacy_disposition_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'payroll_item_legacy_dispositions are append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS payroll_item_legacy_dispositions_append_only ON payroll_item_legacy_dispositions;
CREATE TRIGGER payroll_item_legacy_dispositions_append_only
BEFORE UPDATE OR DELETE ON payroll_item_legacy_dispositions
FOR EACH ROW EXECUTE FUNCTION prevent_payroll_item_legacy_disposition_mutation();

-- 20261003020100_create_direct_deposit_payment_confirmations.rb
CREATE OR REPLACE FUNCTION prevent_check_evidence_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION '% records are append-only', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS direct_deposit_payment_confirmations_append_only ON direct_deposit_payment_confirmations;
CREATE TRIGGER direct_deposit_payment_confirmations_append_only
BEFORE UPDATE OR DELETE ON direct_deposit_payment_confirmations
FOR EACH ROW EXECUTE FUNCTION prevent_check_evidence_mutation();

-- 20261003020200_create_non_employee_check_supersessions.rb
CREATE OR REPLACE FUNCTION protect_non_employee_check_supersession() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'Non-employee check supersession evidence is append-only';
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS protect_non_employee_check_supersessions ON non_employee_check_supersessions;
CREATE TRIGGER protect_non_employee_check_supersessions
  BEFORE UPDATE OR DELETE ON non_employee_check_supersessions
  FOR EACH ROW EXECUTE FUNCTION protect_non_employee_check_supersession();

-- 20261003020300_harden_non_employee_check_supersessions.rb
CREATE OR REPLACE FUNCTION validate_non_employee_check_supersession_tenant() RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM non_employee_checks c
    JOIN payroll_items p ON p.id = NEW.payroll_item_id
    JOIN companies co ON co.id = c.company_id
    JOIN users u ON u.id = NEW.user_id
    WHERE c.id = NEW.non_employee_check_id
      AND c.company_id = NEW.company_id
      AND p.company_id = NEW.company_id
      AND u.organization_id = co.organization_id
  ) THEN
    RAISE EXCEPTION 'Supersession records must belong to the same company and reviewer organization';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS validate_non_employee_check_supersession_tenant_on_insert ON non_employee_check_supersessions;
CREATE TRIGGER validate_non_employee_check_supersession_tenant_on_insert
  BEFORE INSERT ON non_employee_check_supersessions
  FOR EACH ROW EXECUTE FUNCTION validate_non_employee_check_supersession_tenant();

-- 20261003020400_validate_non_employee_check_supersession_facts.rb
CREATE OR REPLACE FUNCTION validate_non_employee_check_supersession_tenant() RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM non_employee_checks c
    JOIN payroll_items p ON p.id = NEW.payroll_item_id
    JOIN pay_periods pp ON pp.id = p.pay_period_id
    JOIN employees e ON e.id = p.employee_id
    JOIN companies co ON co.id = c.company_id
    JOIN users u ON u.id = NEW.user_id
    JOIN check_events d ON d.id = (NEW.verified_facts->>'delivery_event_id')::bigint
    WHERE c.id = NEW.non_employee_check_id
      AND c.company_id = NEW.company_id
      AND p.company_id = NEW.company_id
      AND pp.company_id = NEW.company_id
      AND e.company_id = NEW.company_id
      AND u.organization_id = co.organization_id
      AND c.pay_period_id IS NULL AND c.voided = false
      AND c.printed_at IS NOT NULL AND c.paid_at IS NULL
      AND c.payment_method = 'check'
      AND NOT EXISTS (SELECT 1 FROM payroll_liability_check_allocations a WHERE a.non_employee_check_id = c.id)
      AND pp.status = 'committed' AND p.voided = false
      AND (p.payment_delivery_method IS NULL OR p.payment_delivery_method = 'paper_check')
      AND d.payroll_item_id = p.id AND d.event_type = 'delivered'
      AND d.check_number = p.check_number
      AND c.check_number ~ '^[0-9]+$' AND p.check_number ~ '^[0-9]+$'
      AND coalesce(nullif(ltrim(c.check_number, '0'), ''), '0') = coalesce(nullif(ltrim(p.check_number, '0'), ''), '0')
      AND c.amount = p.net_pay
      AND NEW.verified_facts->'recipient_verified' = 'true'::jsonb
      AND NEW.verified_facts->>'standalone_payee' = c.payable_to
      AND NEW.verified_facts->>'payroll_employee_id' = p.employee_id::text
      AND NEW.verified_facts->>'payroll_employee_name' = concat_ws(' ', nullif(btrim(e.first_name), ''), nullif(btrim(e.middle_name), ''), nullif(btrim(e.last_name), ''))
      AND NEW.verified_facts->>'standalone_check_number' = c.check_number
      AND NEW.verified_facts->>'payroll_check_number' = p.check_number
      AND NEW.verified_facts->>'normalized_check_number' = coalesce(nullif(ltrim(p.check_number, '0'), ''), '0')
      AND (NEW.verified_facts->>'standalone_amount')::numeric = c.amount
      AND (NEW.verified_facts->>'payroll_net_amount')::numeric = p.net_pay
      AND NEW.verified_facts->>'delivered_on' = d.effective_on::text
      AND NEW.verified_facts->>'delivery_evidence_type' IS NOT DISTINCT FROM d.evidence_type
      AND NEW.verified_facts->>'delivery_evidence_reference' IS NOT DISTINCT FROM d.evidence_reference
  ) THEN
    RAISE EXCEPTION 'Supersession requires matching company, check, amount, recipient attestation, and delivery evidence';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 20261003020500_create_check_supersession_rollout_approvals.rb
CREATE OR REPLACE FUNCTION protect_check_supersession_rollout_approval() RETURNS trigger AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'Check supersession rollout approvals are append-only';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM companies c JOIN users u ON u.id = NEW.approved_by_id
    WHERE c.id = NEW.company_id AND c.payroll_environment = 'live'
      AND u.organization_id = c.organization_id AND u.active = true
      AND u.role IN (5, 6)
  ) OR length(btrim(NEW.reason)) < 20 THEN
    RAISE EXCEPTION 'Live-check rollout approval requires an active organization administrator and documented reason';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS protect_check_supersession_rollout_approvals ON check_supersession_rollout_approvals;
CREATE TRIGGER protect_check_supersession_rollout_approvals
  BEFORE INSERT OR UPDATE OR DELETE ON check_supersession_rollout_approvals
  FOR EACH ROW EXECUTE FUNCTION protect_check_supersession_rollout_approval();

-- 20261003020600_enforce_check_supersession_rollout_approval.rb
CREATE OR REPLACE FUNCTION enforce_check_supersession_rollout_approval() RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM companies c JOIN users u ON u.id = NEW.user_id
    WHERE c.id = NEW.company_id AND u.organization_id = c.organization_id
      AND u.active = true AND u.role IN (5, 6, 0, 1)
  ) THEN
    RAISE EXCEPTION 'Check supersession requires an active manager or administrator';
  END IF;
  IF EXISTS (SELECT 1 FROM companies WHERE id = NEW.company_id AND payroll_environment = 'live')
    AND NOT EXISTS (SELECT 1 FROM check_supersession_rollout_approvals WHERE company_id = NEW.company_id) THEN
    RAISE EXCEPTION 'Live-check supersession requires company-specific rollout approval';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS enforce_check_supersession_rollout_approval_on_insert ON non_employee_check_supersessions;
CREATE TRIGGER enforce_check_supersession_rollout_approval_on_insert
  BEFORE INSERT ON non_employee_check_supersessions
  FOR EACH ROW EXECUTE FUNCTION enforce_check_supersession_rollout_approval();

-- 20261003020700_prevent_voiding_superseded_payroll_items.rb
CREATE OR REPLACE FUNCTION prevent_voiding_superseded_payroll_item() RETURNS trigger AS $$
BEGIN
  IF NEW.voided = true AND OLD.voided = false
    AND EXISTS (SELECT 1 FROM non_employee_check_supersessions WHERE payroll_item_id = OLD.id) THEN
    RAISE EXCEPTION 'A payroll check linked to a duplicate software record cannot be voided';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS prevent_voiding_superseded_payroll_item_on_update ON payroll_items;
CREATE TRIGGER prevent_voiding_superseded_payroll_item_on_update
  BEFORE UPDATE OF voided ON payroll_items
  FOR EACH ROW EXECUTE FUNCTION prevent_voiding_superseded_payroll_item();

-- 20261003020800_prevent_voiding_periods_with_superseded_checks.rb
CREATE OR REPLACE FUNCTION prevent_voiding_period_with_superseded_checks() RETURNS trigger AS $$
BEGIN
  IF NEW.correction_status = 'voided' AND OLD.correction_status IS DISTINCT FROM 'voided'
    AND EXISTS (
      SELECT 1 FROM payroll_items p
      JOIN non_employee_check_supersessions s ON s.payroll_item_id = p.id
      WHERE p.pay_period_id = OLD.id
    ) THEN
    RAISE EXCEPTION 'A pay period with a payroll check linked to a duplicate software record cannot be voided';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS prevent_voiding_period_with_superseded_checks_on_update ON pay_periods;
CREATE TRIGGER prevent_voiding_period_with_superseded_checks_on_update
  BEFORE UPDATE OF correction_status ON pay_periods
  FOR EACH ROW EXECUTE FUNCTION prevent_voiding_period_with_superseded_checks();

-- 20261003020900_protect_superseded_payroll_item_facts.rb
CREATE OR REPLACE FUNCTION protect_superseded_payroll_item_facts() RETURNS trigger AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM non_employee_check_supersessions WHERE payroll_item_id = OLD.id)
    AND (
      NEW.check_number IS DISTINCT FROM OLD.check_number OR
      NEW.net_pay IS DISTINCT FROM OLD.net_pay OR
      NEW.employee_id IS DISTINCT FROM OLD.employee_id OR
      NEW.pay_period_id IS DISTINCT FROM OLD.pay_period_id OR
      NEW.company_id IS DISTINCT FROM OLD.company_id OR
      NEW.payment_delivery_method IS DISTINCT FROM OLD.payment_delivery_method
    ) THEN
    RAISE EXCEPTION 'A payroll check linked to a duplicate software record cannot change verified payment facts';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS protect_superseded_payroll_item_facts_on_update ON payroll_items;
CREATE TRIGGER protect_superseded_payroll_item_facts_on_update
  BEFORE UPDATE OF check_number, net_pay, employee_id, pay_period_id, company_id, payment_delivery_method ON payroll_items
  FOR EACH ROW EXECUTE FUNCTION protect_superseded_payroll_item_facts();

-- 20261003021300_create_time_tracking_legacy_identity_bindings.rb
CREATE OR REPLACE FUNCTION protect_legacy_identity_binding() RETURNS trigger AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'Legacy identity bindings are append-only';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM time_tracking_entry_allocations a
    JOIN time_tracking_imports i ON i.id = a.time_tracking_import_id
    JOIN time_tracking_sources s ON s.id = a.time_tracking_source_id
    JOIN payroll_items p ON p.id = a.payroll_item_id
    JOIN employees e ON e.id = a.employee_id
    JOIN pay_periods pp ON pp.id = a.pay_period_id
    JOIN companies c ON c.id = a.company_id
    JOIN users u ON u.id = NEW.approved_by_id
    JOIN time_tracking_employee_mappings m ON m.id = NEW.time_tracking_employee_mapping_id
    WHERE a.id = NEW.time_tracking_entry_allocation_id AND a.source_user_uuid IS NULL
      AND a.company_id = NEW.company_id AND s.company_id = c.id AND p.company_id = c.id
      AND e.company_id = c.id AND pp.company_id = c.id AND p.employee_id = e.id
      AND p.pay_period_id = pp.id AND i.pay_period_id = pp.id AND i.time_tracking_source_id = s.id
      AND a.time_tracking_source_id = NEW.time_tracking_source_id AND a.employee_id = NEW.employee_id
      AND a.source_user_id = NEW.source_user_id AND a.source_time_entry_id = NEW.source_time_entry_id
      AND a.line_key = NEW.source_line_key AND a.original_work_date = NEW.original_work_date
      AND i.external_batch_id = NEW.external_batch_id AND i.external_batch_checksum = NEW.batch_checksum
      AND s.expected_source_instance_id::text = NEW.source_instance_id::text
      AND m.company_id = c.id AND m.time_tracking_source_id = s.id AND m.employee_id = e.id
      AND m.source_user_id = a.source_user_id AND (m.source_user_uuid IS NULL OR m.source_user_uuid::text = NEW.source_user_uuid::text)
      AND u.organization_id = c.organization_id AND u.active = true AND u.role IN (0,1,5,6)
  ) THEN
    RAISE EXCEPTION 'Legacy identity binding tenant, source, owner, or batch evidence changed';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS legacy_identity_binding_integrity ON time_tracking_legacy_identity_bindings;
CREATE TRIGGER legacy_identity_binding_integrity
BEFORE INSERT OR UPDATE OR DELETE ON time_tracking_legacy_identity_bindings
FOR EACH ROW EXECUTE FUNCTION protect_legacy_identity_binding();

CREATE OR REPLACE FUNCTION protect_bound_legacy_allocation() RETURNS trigger AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM time_tracking_legacy_identity_bindings WHERE time_tracking_entry_allocation_id = OLD.id) THEN
    RAISE EXCEPTION 'An allocation with approved legacy identity evidence is immutable';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS bound_legacy_allocation_immutable ON time_tracking_entry_allocations;
CREATE TRIGGER bound_legacy_allocation_immutable
BEFORE UPDATE OR DELETE ON time_tracking_entry_allocations
FOR EACH ROW EXECUTE FUNCTION protect_bound_legacy_allocation();

-- 20261003021400_gate_existing_sources_on_approved_history.rb
CREATE OR REPLACE FUNCTION protect_verified_history_receipt() RETURNS trigger AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Verified history receipts are append-only'; END IF;
  IF NEW.coverage_verified AND (
    NEW.accepted_manifest_sha256 IS DISTINCT FROM NEW.manifest_sha256 OR
    NEW.source_instance_id IS NULL OR NEW.release_owner IS NULL OR length(btrim(NEW.release_owner)) = 0 OR
    NOT EXISTS (SELECT 1 FROM time_tracking_sources s JOIN companies c ON c.id = s.company_id
      JOIN users u ON u.id = NEW.approved_by_id WHERE s.id = NEW.time_tracking_source_id
      AND s.company_id = NEW.company_id AND s.expected_source_instance_id::text = NEW.source_instance_id::text
      AND u.organization_id = c.organization_id AND u.active = true AND u.role IN (0,1,5,6))
  ) THEN RAISE EXCEPTION 'Verified history receipt requires accepted installation-bound owner approval'; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS verified_history_receipt_integrity ON aire_verified_history_rollout_receipts;
CREATE TRIGGER verified_history_receipt_integrity BEFORE INSERT OR UPDATE OR DELETE
ON aire_verified_history_rollout_receipts FOR EACH ROW EXECUTE FUNCTION protect_verified_history_receipt();

-- 20261003040000_scope_historical_reconciliation_approvers.rb
CREATE OR REPLACE FUNCTION historical_time_reconciliation_actor_allowed(actor_id bigint, target_company_id bigint)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM users u JOIN companies c ON c.id = target_company_id
    JOIN organizations o ON o.id = c.organization_id
    WHERE u.id = actor_id AND u.active = true AND c.active = true
      AND c.test_workspace_archived_at IS NULL AND o.status = 'active'
      AND (u.role = 5 OR (u.organization_id = c.organization_id AND (
        u.role IN (0,6) OR (u.role IN (1,3) AND (
          EXISTS (SELECT 1 FROM company_assignments ca WHERE ca.user_id = u.id AND ca.company_id = c.id
            AND (ca.expires_at IS NULL OR ca.expires_at > CURRENT_TIMESTAMP))
          OR (u.company_id = c.id AND NOT EXISTS (
            SELECT 1 FROM company_assignments ca JOIN companies assigned ON assigned.id = ca.company_id
            WHERE ca.user_id = u.id AND assigned.organization_id = u.organization_id
              AND assigned.test_workspace_archived_at IS NULL
              AND (ca.expires_at IS NULL OR ca.expires_at > CURRENT_TIMESTAMP)
          ))
        ))
      )))
  );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION protect_legacy_identity_binding() RETURNS trigger AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'Legacy identity bindings are append-only';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM time_tracking_entry_allocations a
    JOIN time_tracking_imports i ON i.id = a.time_tracking_import_id
    JOIN time_tracking_sources s ON s.id = a.time_tracking_source_id
    JOIN payroll_items p ON p.id = a.payroll_item_id
    JOIN employees e ON e.id = a.employee_id
    JOIN pay_periods pp ON pp.id = a.pay_period_id
    JOIN companies c ON c.id = a.company_id
    JOIN users u ON u.id = NEW.approved_by_id
    JOIN time_tracking_employee_mappings m ON m.id = NEW.time_tracking_employee_mapping_id
    WHERE a.id = NEW.time_tracking_entry_allocation_id AND a.source_user_uuid IS NULL
      AND a.company_id = NEW.company_id AND s.company_id = c.id AND p.company_id = c.id
      AND e.company_id = c.id AND pp.company_id = c.id AND p.employee_id = e.id
      AND p.pay_period_id = pp.id AND i.pay_period_id = pp.id AND i.time_tracking_source_id = s.id
      AND a.time_tracking_source_id = NEW.time_tracking_source_id AND a.employee_id = NEW.employee_id
      AND a.source_user_id = NEW.source_user_id AND a.source_time_entry_id = NEW.source_time_entry_id
      AND a.line_key = NEW.source_line_key AND a.original_work_date = NEW.original_work_date
      AND i.external_batch_id = NEW.external_batch_id AND i.external_batch_checksum = NEW.batch_checksum
      AND s.expected_source_instance_id::text = NEW.source_instance_id::text
      AND m.company_id = c.id AND m.time_tracking_source_id = s.id AND m.employee_id = e.id
      AND m.source_user_id = a.source_user_id AND (m.source_user_uuid IS NULL OR m.source_user_uuid::text = NEW.source_user_uuid::text)
      AND historical_time_reconciliation_actor_allowed(u.id, c.id)
  ) THEN
    RAISE EXCEPTION 'Legacy identity binding tenant, source, owner, or batch evidence changed';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION protect_verified_history_receipt() RETURNS trigger AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Verified history receipts are append-only'; END IF;
  IF NEW.coverage_verified AND (
    NEW.accepted_manifest_sha256 IS DISTINCT FROM NEW.manifest_sha256 OR
    NEW.source_instance_id IS NULL OR NEW.release_owner IS NULL OR length(btrim(NEW.release_owner)) = 0 OR
    NOT EXISTS (SELECT 1 FROM time_tracking_sources s JOIN companies c ON c.id = s.company_id
      JOIN users u ON u.id = NEW.approved_by_id WHERE s.id = NEW.time_tracking_source_id
      AND s.company_id = NEW.company_id AND s.expected_source_instance_id::text = NEW.source_instance_id::text
      AND historical_time_reconciliation_actor_allowed(u.id, c.id))
  ) THEN RAISE EXCEPTION 'Verified history receipt requires accepted installation-bound owner approval'; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 20261003050000_preserve_supersession_employee_name_format.rb
CREATE OR REPLACE FUNCTION validate_non_employee_check_supersession_tenant() RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM non_employee_checks c
    JOIN payroll_items p ON p.id = NEW.payroll_item_id
    JOIN pay_periods pp ON pp.id = p.pay_period_id
    JOIN employees e ON e.id = p.employee_id
    JOIN companies co ON co.id = c.company_id
    JOIN users u ON u.id = NEW.user_id
    JOIN check_events d ON d.id = (NEW.verified_facts->>'delivery_event_id')::bigint
    WHERE c.id = NEW.non_employee_check_id
      AND c.company_id = NEW.company_id
      AND p.company_id = NEW.company_id
      AND pp.company_id = NEW.company_id
      AND e.company_id = NEW.company_id
      AND u.organization_id = co.organization_id
      AND c.pay_period_id IS NULL AND c.voided = false
      AND c.printed_at IS NOT NULL AND c.paid_at IS NULL
      AND c.payment_method = 'check'
      AND NOT EXISTS (SELECT 1 FROM payroll_liability_check_allocations a WHERE a.non_employee_check_id = c.id)
      AND pp.status = 'committed' AND p.voided = false
      AND (p.payment_delivery_method IS NULL OR p.payment_delivery_method = 'paper_check')
      AND d.payroll_item_id = p.id AND d.event_type = 'delivered'
      AND d.check_number = p.check_number
      AND c.check_number ~ '^[0-9]+$' AND p.check_number ~ '^[0-9]+$'
      AND coalesce(nullif(ltrim(c.check_number, '0'), ''), '0') = coalesce(nullif(ltrim(p.check_number, '0'), ''), '0')
      AND c.amount = p.net_pay
      AND NEW.verified_facts->'recipient_verified' = 'true'::jsonb
      AND NEW.verified_facts->>'standalone_payee' = c.payable_to
      AND NEW.verified_facts->>'payroll_employee_id' = p.employee_id::text
      AND NEW.verified_facts->>'payroll_employee_name' = concat_ws(' ', CASE WHEN e.first_name !~ '^[[:space:]]*$' THEN e.first_name END, CASE WHEN e.middle_name !~ '^[[:space:]]*$' THEN e.middle_name END, CASE WHEN e.last_name !~ '^[[:space:]]*$' THEN e.last_name END)
      AND NEW.verified_facts->>'standalone_check_number' = c.check_number
      AND NEW.verified_facts->>'payroll_check_number' = p.check_number
      AND NEW.verified_facts->>'normalized_check_number' = coalesce(nullif(ltrim(p.check_number, '0'), ''), '0')
      AND (NEW.verified_facts->>'standalone_amount')::numeric = c.amount
      AND (NEW.verified_facts->>'payroll_net_amount')::numeric = p.net_pay
      AND NEW.verified_facts->>'delivered_on' = d.effective_on::text
      AND NEW.verified_facts->>'delivery_evidence_type' IS NOT DISTINCT FROM d.evidence_type
      AND NEW.verified_facts->>'delivery_evidence_reference' IS NOT DISTINCT FROM d.evidence_reference
  ) THEN
    RAISE EXCEPTION 'Supersession requires matching company, check, amount, recipient attestation, and delivery evidence';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 20261006090000_complete_retirement_compliance_inputs.rb
CREATE OR REPLACE FUNCTION prevent_retirement_year_input_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'employee_retirement_year_inputs are append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS retirement_year_inputs_append_only ON employee_retirement_year_inputs;
CREATE TRIGGER retirement_year_inputs_append_only
BEFORE UPDATE OR DELETE ON employee_retirement_year_inputs
FOR EACH ROW EXECUTE FUNCTION prevent_retirement_year_input_mutation();

-- 20261009070000_create_time_tracking_correction_dispositions.rb
CREATE OR REPLACE FUNCTION prevent_time_tracking_correction_evidence_mutation() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'Exact source accounting correction evidence is append-only';
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS immutable_time_tracking_correction_dispositions ON time_tracking_correction_dispositions;
CREATE TRIGGER immutable_time_tracking_correction_dispositions
  BEFORE UPDATE OR DELETE ON time_tracking_correction_dispositions
  FOR EACH ROW EXECUTE FUNCTION prevent_time_tracking_correction_evidence_mutation();
CREATE OR REPLACE FUNCTION protect_time_tracking_correction_receipt_evidence() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' OR NEW.payload IS DISTINCT FROM OLD.payload OR
    NEW.event_id IS DISTINCT FROM OLD.event_id OR
    NEW.time_tracking_correction_disposition_id IS DISTINCT FROM OLD.time_tracking_correction_disposition_id THEN
    RAISE EXCEPTION 'Exact source accounting receipt evidence is immutable';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS immutable_time_tracking_correction_receipts ON time_tracking_correction_receipts;
CREATE TRIGGER immutable_time_tracking_correction_receipts
  BEFORE UPDATE OR DELETE ON time_tracking_correction_receipts
  FOR EACH ROW EXECUTE FUNCTION protect_time_tracking_correction_receipt_evidence();

-- 20261011050000_add_financial_correction_source_lineage.rb
CREATE OR REPLACE FUNCTION protect_financial_correction_source_evidence() RETURNS trigger AS $$
BEGIN
  IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
    RAISE EXCEPTION 'Financial correction Source evidence is append-only';
  END IF;
  IF (to_jsonb(NEW) - ARRAY['accepted_receipt','accepted_at','updated_at']) IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY['accepted_receipt','accepted_at','updated_at']) OR
     (OLD.accepted_receipt <> '{}'::jsonb AND (NEW.accepted_receipt IS DISTINCT FROM OLD.accepted_receipt OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at)) THEN
    RAISE EXCEPTION 'Financial correction Source evidence is immutable';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS immutable_financial_correction_source_links ON time_tracking_financial_correction_links;
CREATE TRIGGER immutable_financial_correction_source_links BEFORE UPDATE OR DELETE ON time_tracking_financial_correction_links
  FOR EACH ROW EXECUTE FUNCTION protect_financial_correction_source_evidence();
DROP TRIGGER IF EXISTS immutable_financial_correction_source_links_truncate ON time_tracking_financial_correction_links;
CREATE TRIGGER immutable_financial_correction_source_links_truncate BEFORE TRUNCATE ON time_tracking_financial_correction_links
  FOR EACH STATEMENT EXECUTE FUNCTION protect_financial_correction_source_evidence();
CREATE OR REPLACE FUNCTION protect_financial_correction_origin_and_outbox() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    IF EXISTS (SELECT 1 FROM aire_payroll_entry_acknowledgements WHERE financial_correction_link_id IS NOT NULL) THEN
      RAISE EXCEPTION 'Financial correction outbox is append-only';
    END IF;
    RETURN NULL;
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF OLD.financial_correction_link_id IS NOT NULL THEN
      RAISE EXCEPTION 'Financial correction outbox is append-only';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_TABLE_NAME = 'payroll_items' THEN
    IF OLD.financial_correction_origin_item_id IS NOT NULL AND NEW.financial_correction_origin_item_id IS DISTINCT FROM OLD.financial_correction_origin_item_id THEN
      RAISE EXCEPTION 'Financial correction origin is immutable';
    END IF;
  ELSE
    IF NEW.financial_correction_link_id IS DISTINCT FROM OLD.financial_correction_link_id OR NEW.wire_payload IS DISTINCT FROM OLD.wire_payload OR
       (OLD.financial_correction_link_id IS NOT NULL AND
        (to_jsonb(NEW) - ARRAY['delivered_at','enqueued_at','last_error','updated_at']) IS DISTINCT FROM
        (to_jsonb(OLD) - ARRAY['delivered_at','enqueued_at','last_error','updated_at'])) THEN
      RAISE EXCEPTION 'Financial correction outbox payload is immutable';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS immutable_financial_correction_origin ON payroll_items;
CREATE TRIGGER immutable_financial_correction_origin BEFORE UPDATE ON payroll_items
  FOR EACH ROW EXECUTE FUNCTION protect_financial_correction_origin_and_outbox();
DROP TRIGGER IF EXISTS immutable_financial_correction_outbox ON aire_payroll_entry_acknowledgements;
CREATE TRIGGER immutable_financial_correction_outbox BEFORE UPDATE OR DELETE ON aire_payroll_entry_acknowledgements
  FOR EACH ROW EXECUTE FUNCTION protect_financial_correction_origin_and_outbox();
DROP TRIGGER IF EXISTS immutable_financial_correction_outbox_truncate ON aire_payroll_entry_acknowledgements;
CREATE TRIGGER immutable_financial_correction_outbox_truncate BEFORE TRUNCATE ON aire_payroll_entry_acknowledgements
  FOR EACH STATEMENT EXECUTE FUNCTION protect_financial_correction_origin_and_outbox();

-- 20261014020000_capture_time_tracking_allocation_earnings.rb
CREATE OR REPLACE FUNCTION protect_source_earning_capture() RETURNS trigger AS $$
BEGIN
  IF OLD.earning_snapshot <> '{}'::jsonb THEN
    RAISE EXCEPTION 'Captured source earning allocations are append-only';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.earning_snapshot IS DISTINCT FROM OLD.earning_snapshot THEN
    RAISE EXCEPTION 'Historical source earning captures cannot be invented';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS source_earning_capture_immutable ON time_tracking_entry_allocations;
CREATE TRIGGER source_earning_capture_immutable BEFORE UPDATE OR DELETE ON time_tracking_entry_allocations
  FOR EACH ROW EXECUTE FUNCTION protect_source_earning_capture();

-- 20261024100000_create_payroll_item_fica_basis_proofs.rb
CREATE OR REPLACE FUNCTION prevent_fica_basis_proof_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'payroll_item_fica_basis_proofs are append-only';
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS fica_basis_proofs_append_only ON payroll_item_fica_basis_proofs;
CREATE TRIGGER fica_basis_proofs_append_only
BEFORE UPDATE OR DELETE ON payroll_item_fica_basis_proofs
FOR EACH ROW EXECUTE FUNCTION prevent_fica_basis_proof_mutation();
DROP TRIGGER IF EXISTS fica_basis_proofs_no_truncate ON payroll_item_fica_basis_proofs;
CREATE TRIGGER fica_basis_proofs_no_truncate BEFORE TRUNCATE ON payroll_item_fica_basis_proofs
FOR EACH STATEMENT EXECUTE FUNCTION prevent_fica_basis_proof_mutation();

-- Audited, configure-once automatic-lock rollout boundary.
CREATE OR REPLACE FUNCTION protect_time_tracking_lock_rollout() RETURNS trigger AS $$
BEGIN
  IF NEW.cutoff_enforcement_starts_on IS DISTINCT FROM OLD.cutoff_enforcement_starts_on THEN
    RAISE EXCEPTION 'the configured payroll lock rollout boundary is immutable';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS time_tracking_lock_rollout_immutable ON time_tracking_sources;
CREATE TRIGGER time_tracking_lock_rollout_immutable BEFORE UPDATE ON time_tracking_sources
FOR EACH ROW EXECUTE FUNCTION protect_time_tracking_lock_rollout();

CREATE OR REPLACE FUNCTION audit_time_tracking_lock_rollout() RETURNS trigger AS $$
BEGIN
  IF NEW.source_type = 'aire_services' THEN
    INSERT INTO audit_logs (action, actor_name, actor_role, company_id, organization_id,
      record_type, record_id, event_category, metadata, created_at)
    SELECT 'time_tracking_source#lock_rollout_configured', 'Approved lock rollout', 'system',
      NEW.company_id, companies.organization_id, 'TimeTrackingSource', NEW.id, 'integration',
      jsonb_build_object('cutoff_enforcement_starts_on', NEW.cutoff_enforcement_starts_on,
        'reason', 'Approved rollout: periods before October 16, 2026 lock only on explicit operator request'),
      CURRENT_TIMESTAMP
    FROM companies WHERE companies.id = NEW.company_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS time_tracking_lock_rollout_audit ON time_tracking_sources;
CREATE TRIGGER time_tracking_lock_rollout_audit AFTER INSERT ON time_tracking_sources
FOR EACH ROW EXECUTE FUNCTION audit_time_tracking_lock_rollout();
