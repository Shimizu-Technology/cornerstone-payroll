# frozen_string_literal: true

class KeepImportRolloutDigestStable < ActiveRecord::Migration[8.1]
  def down
    execute "SET LOCAL lock_timeout = '5s'"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION historical_import_rollout_review(source_id bigint) RETURNS jsonb AS $$
        WITH inventory AS (
          SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'import_id', i.id, 'run_id', p.id,
            'import_sha256', encode(sha256(convert_to(to_jsonb(i)::text, 'UTF8')), 'hex'),
            'run_sha256', encode(sha256(convert_to(to_jsonb(p)::text, 'UTF8')), 'hex')
          ) ORDER BY i.id), '[]'::jsonb) AS rows
          FROM time_tracking_imports i JOIN pay_periods p ON p.id = i.pay_period_id
          WHERE i.time_tracking_source_id = source_id
        ) SELECT jsonb_build_object('inventory', rows,
          'sha256', encode(sha256(convert_to(rows::text, 'UTF8')), 'hex')) FROM inventory;
      $$ LANGUAGE sql STABLE;

      CREATE OR REPLACE FUNCTION protect_financial_correction_source_evidence() RETURNS trigger AS $$
      BEGIN
        IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
          RAISE EXCEPTION 'Financial correction Source evidence is append-only';
        END IF;
        -- Company ownership is the only field a legacy evidence row may gain.
        IF to_jsonb(OLD)->>'company_id' IS NULL AND to_jsonb(NEW)->>'company_id' IS NOT NULL
           AND (to_jsonb(NEW) - 'company_id') = (to_jsonb(OLD) - 'company_id') THEN
          RETURN NEW;
        END IF;
        IF (to_jsonb(NEW) - ARRAY['accepted_receipt','accepted_at','updated_at']) IS DISTINCT FROM
           (to_jsonb(OLD) - ARRAY['accepted_receipt','accepted_at','updated_at']) OR
           (OLD.accepted_receipt <> '{}'::jsonb AND (NEW.accepted_receipt IS DISTINCT FROM OLD.accepted_receipt OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at)) THEN
          RAISE EXCEPTION 'Financial correction Source evidence is immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

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
          -- Company ownership is the only field a legacy evidence row may gain.
          IF to_jsonb(OLD)->>'company_id' IS NULL AND to_jsonb(NEW)->>'company_id' IS NOT NULL
             AND (to_jsonb(NEW) - 'company_id') = (to_jsonb(OLD) - 'company_id') THEN
            RETURN NEW;
          END IF;
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
    SQL
  end

  def up
    execute "SET LOCAL lock_timeout = '5s'"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION historical_import_rollout_review(source_id bigint) RETURNS jsonb AS $$
        WITH inventory AS (
          SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'import_id', i.id, 'run_id', p.id,
            'import_sha256', encode(sha256(convert_to((to_jsonb(i) - 'company_id')::text, 'UTF8')), 'hex'),
            'run_sha256', encode(sha256(convert_to(to_jsonb(p)::text, 'UTF8')), 'hex')
          ) ORDER BY i.id), '[]'::jsonb) AS rows
          FROM time_tracking_imports i JOIN pay_periods p ON p.id = i.pay_period_id
          WHERE i.time_tracking_source_id = source_id
        ) SELECT jsonb_build_object('inventory', rows,
          'sha256', encode(sha256(convert_to(rows::text, 'UTF8')), 'hex')) FROM inventory;
      $$ LANGUAGE sql STABLE;

      CREATE OR REPLACE FUNCTION protect_financial_correction_source_evidence() RETURNS trigger AS $$
      DECLARE
        mutable_fields text[] := ARRAY['accepted_receipt','accepted_at','updated_at'];
      BEGIN
        IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
          RAISE EXCEPTION 'Financial correction Source evidence is append-only';
        END IF;
        -- The composite FK checks the first assignment, including on a normal save.
        IF OLD.company_id IS NULL THEN
          mutable_fields := array_append(mutable_fields, 'company_id');
        END IF;
        IF (to_jsonb(NEW) - mutable_fields) IS DISTINCT FROM
           (to_jsonb(OLD) - mutable_fields) OR
           (OLD.accepted_receipt <> '{}'::jsonb AND (NEW.accepted_receipt IS DISTINCT FROM OLD.accepted_receipt OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at)) THEN
          RAISE EXCEPTION 'Financial correction Source evidence is immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE OR REPLACE FUNCTION protect_financial_correction_origin_and_outbox() RETURNS trigger AS $$
      DECLARE
        mutable_fields text[] := ARRAY['delivered_at','enqueued_at','last_error','updated_at'];
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
          -- The composite FK checks the first assignment, including on a normal save.
          IF OLD.company_id IS NULL THEN
            mutable_fields := array_append(mutable_fields, 'company_id');
          END IF;
          IF NEW.financial_correction_link_id IS DISTINCT FROM OLD.financial_correction_link_id OR NEW.wire_payload IS DISTINCT FROM OLD.wire_payload OR
             (OLD.financial_correction_link_id IS NOT NULL AND
              (to_jsonb(NEW) - mutable_fields) IS DISTINCT FROM
              (to_jsonb(OLD) - mutable_fields)) THEN
            RAISE EXCEPTION 'Financial correction outbox payload is immutable';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end
