# frozen_string_literal: true

class ValidateNonEmployeeCheckSupersessionFacts < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
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
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Do not weaken append-only supersession evidence validation"
  end
end
