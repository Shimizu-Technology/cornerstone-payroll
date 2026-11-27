# frozen_string_literal: true

class ProtectPayPeriodVerificationAcknowledgementsAppendOnly < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION reject_pay_period_verification_acknowledgement_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'pay_period_verification_acknowledgements is append-only';
      END;
      $$;
      DROP TRIGGER IF EXISTS pay_period_verification_acknowledgements_append_only ON pay_period_verification_acknowledgements;
      CREATE TRIGGER pay_period_verification_acknowledgements_append_only BEFORE UPDATE OR DELETE ON pay_period_verification_acknowledgements
        FOR EACH ROW EXECUTE FUNCTION reject_pay_period_verification_acknowledgement_mutation();
      DROP TRIGGER IF EXISTS pay_period_verification_acknowledgements_no_truncate ON pay_period_verification_acknowledgements;
      CREATE TRIGGER pay_period_verification_acknowledgements_no_truncate BEFORE TRUNCATE ON pay_period_verification_acknowledgements
        FOR EACH STATEMENT EXECUTE FUNCTION reject_pay_period_verification_acknowledgement_mutation();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Pay period verification acknowledgement evidence must be retained"
  end
end
