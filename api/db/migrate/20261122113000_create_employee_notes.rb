# frozen_string_literal: true

class CreateEmployeeNotes < ActiveRecord::Migration[8.1]
  def up
    create_table :employee_notes do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :employee, null: false, foreign_key: true, index: true
      t.text :body, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime :hidden_at
      t.references :hidden_by, null: true, foreign_key: { to_table: :users }, index: true
      t.text :hidden_reason

      t.timestamps
    end

    add_index :employee_notes,
              [ :company_id, :employee_id, :created_at, :id ],
              name: "index_employee_notes_on_company_employee_created"

    add_check_constraint :employee_notes,
                         "char_length(btrim(body)) >= 1 AND char_length(body) <= 2000",
                         name: "employee_notes_body_length"
    add_check_constraint :employee_notes,
                         "(hidden_at IS NULL AND hidden_by_id IS NULL AND hidden_reason IS NULL) OR " \
                         "(hidden_at IS NOT NULL AND hidden_by_id IS NOT NULL AND hidden_reason IS NOT NULL AND " \
                         "char_length(btrim(hidden_reason)) >= 1 AND char_length(hidden_reason) <= 500)",
                         name: "employee_notes_hidden_fields_consistent"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_employee_notes_update()
      RETURNS trigger AS $$
      BEGIN
        IF OLD.hidden_at IS NOT NULL THEN
          RAISE EXCEPTION 'Hidden employee notes cannot be modified'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.body IS DISTINCT FROM OLD.body
          OR NEW.company_id IS DISTINCT FROM OLD.company_id
          OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
          OR NEW.created_by_id IS DISTINCT FROM OLD.created_by_id
          OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
          RAISE EXCEPTION 'Employee notes are append-only; immutable columns cannot be updated'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS employee_notes_prevent_immutable_update ON employee_notes;
      CREATE TRIGGER employee_notes_prevent_immutable_update
      BEFORE UPDATE ON employee_notes
      FOR EACH ROW EXECUTE FUNCTION protect_employee_notes_update();

      CREATE OR REPLACE FUNCTION protect_employee_notes_delete()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'Employee notes cannot be deleted; hide the note instead'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS employee_notes_prevent_delete ON employee_notes;
      CREATE TRIGGER employee_notes_prevent_delete
      BEFORE DELETE ON employee_notes
      FOR EACH ROW EXECUTE FUNCTION protect_employee_notes_delete();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS employee_notes_prevent_delete ON employee_notes"
    execute "DROP FUNCTION IF EXISTS protect_employee_notes_delete()"
    execute "DROP TRIGGER IF EXISTS employee_notes_prevent_immutable_update ON employee_notes"
    execute "DROP FUNCTION IF EXISTS protect_employee_notes_update()"
    drop_table :employee_notes
  end
end
