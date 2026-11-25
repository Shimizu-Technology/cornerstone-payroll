# frozen_string_literal: true

# Persisted delivery disclosures are immutable legal records. Counsel approval or
# wording changes must always insert a new version row, never update an existing
# disclosure in place.
class PreventDeliveryDisclosureMutation < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_delivery_disclosure_mutation() RETURNS trigger AS $$
      BEGIN
        IF NEW.kind IS DISTINCT FROM OLD.kind
          OR NEW.version IS DISTINCT FROM OLD.version
          OR NEW.text IS DISTINCT FROM OLD.text
          OR NEW.digest IS DISTINCT FROM OLD.digest
          OR NEW.status IS DISTINCT FROM OLD.status
        THEN
          RAISE EXCEPTION 'delivery_disclosures rows are immutable; insert a new version instead'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS delivery_disclosures_immutable ON delivery_disclosures;
      CREATE TRIGGER delivery_disclosures_immutable
      BEFORE UPDATE OF kind, version, text, digest, status ON delivery_disclosures
      FOR EACH ROW
      EXECUTE FUNCTION prevent_delivery_disclosure_mutation();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS delivery_disclosures_immutable ON delivery_disclosures;
      DROP FUNCTION IF EXISTS prevent_delivery_disclosure_mutation();
    SQL
  end
end
