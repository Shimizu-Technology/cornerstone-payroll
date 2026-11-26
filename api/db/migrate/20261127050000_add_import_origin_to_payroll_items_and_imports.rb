# frozen_string_literal: true

# Track C B3:
# - Adds payroll_items.import_origin ('intake', 'time_tracking', 'timecard_ocr', 'correction')
#   so import-origin checks no longer compare import_source == 'mosa_revel'.
# - Adds payroll_imports.import_origin (jsonb) to record adapter/descriptor version,
#   channel (staff_upload vs portal_revision), re-import supersession, and hand-edit overwrites.
# - Expands payroll_items_bonus_source_check to allow 'import' alongside 'manual' and 'mosa_revel'.
#
# Uses SET LOCAL lock_timeout = '5s', NOT VALID constraints validated outside the DDL lock,
# and batched update_all backfills. Existing triggers on payroll_items only guard voided,
# superseded payment facts, and financial_correction_origin_item_id, so committed rows
# backfill cleanly.
class AddImportOriginToPayrollItemsAndImports < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ITEMS_ORIGIN_CONSTRAINT = "payroll_items_import_origin_check"
  IMPORTS_ORIGIN_CONSTRAINT = "payroll_imports_import_origin_object"
  BONUS_SOURCE_CONSTRAINT = "payroll_items_bonus_source_check"
  BONUS_SOURCE_EXPANDED_TMP = "payroll_items_bonus_source_expanded_check"
  BONUS_SOURCE_ORIGINAL_TMP = "payroll_items_bonus_source_original_check"

  IMPORT_ORIGINS = %w[intake time_tracking timecard_ocr correction].freeze
  INTAKE_SOURCES = %w[mosa_revel spike_email].freeze
  ORIGINAL_BONUS_SOURCES = %w[manual mosa_revel].freeze
  EXPANDED_BONUS_SOURCES = %w[manual mosa_revel import].freeze
  BATCH_SIZE = 1000

  class MigrationPayrollItem < ActiveRecord::Base
    self.table_name = "payroll_items"
  end

  class MigrationPayrollImport < ActiveRecord::Base
    self.table_name = "payroll_imports"
  end

  class MigrationIntakeSession < ActiveRecord::Base
    self.table_name = "payroll_intake_sessions"
  end

  class MigrationSubmissionImport < ActiveRecord::Base
    self.table_name = "payroll_submission_imports"
  end

  class MigrationSubmission < ActiveRecord::Base
    self.table_name = "payroll_submissions"
  end

  def up
    with_lock_timeout do
      add_column :payroll_items, :import_origin, :string, if_not_exists: true
      unless check_constraints(:payroll_items).any? { |c| c.name == ITEMS_ORIGIN_CONSTRAINT }
        add_check_constraint :payroll_items,
                             "import_origin IS NULL OR import_origin IN (#{quoted_list(IMPORT_ORIGINS)})",
                             name: ITEMS_ORIGIN_CONSTRAINT,
                             validate: false
      end

      add_column :payroll_imports, :import_origin, :jsonb, default: {}, null: false, if_not_exists: true
      unless check_constraints(:payroll_imports).any? { |c| c.name == IMPORTS_ORIGIN_CONSTRAINT }
        add_check_constraint :payroll_imports,
                             "jsonb_typeof(import_origin) = 'object'",
                             name: IMPORTS_ORIGIN_CONSTRAINT,
                             validate: false
      end
    end

    replace_bonus_source_constraint!(EXPANDED_BONUS_SOURCES, BONUS_SOURCE_EXPANDED_TMP)

    backfill_payroll_items_import_origin!
    backfill_payroll_imports_import_origin!

    validate_check_constraint :payroll_items, name: ITEMS_ORIGIN_CONSTRAINT
    validate_check_constraint :payroll_imports, name: IMPORTS_ORIGIN_CONSTRAINT
  end

  def down
    MigrationPayrollItem.where(bonus_source: "import").in_batches(of: BATCH_SIZE) do |batch|
      batch.update_all(bonus_source: "mosa_revel")
    end
    replace_bonus_source_constraint!(ORIGINAL_BONUS_SOURCES, BONUS_SOURCE_ORIGINAL_TMP)

    with_lock_timeout do
      remove_check_constraint :payroll_imports, name: IMPORTS_ORIGIN_CONSTRAINT, if_exists: true
      remove_column :payroll_imports, :import_origin, if_exists: true

      remove_check_constraint :payroll_items, name: ITEMS_ORIGIN_CONSTRAINT, if_exists: true
      remove_column :payroll_items, :import_origin, if_exists: true
    end
  end

  private

  def with_lock_timeout
    connection.transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      yield
    end
  end

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end

  def backfill_payroll_items_import_origin!
    before_counts = MigrationPayrollItem.group(:import_source).count
    say "payroll_items row counts by import_source before backfill: #{before_counts.inspect}"

    MigrationPayrollItem.where(import_origin: nil).where.not(correction_for_payroll_item_id: nil).in_batches(of: BATCH_SIZE) do |batch|
      batch.update_all(import_origin: "correction")
    end

    MigrationPayrollItem.where(import_origin: nil, import_source: INTAKE_SOURCES).in_batches(of: BATCH_SIZE) do |batch|
      batch.update_all(import_origin: "intake")
    end

    MigrationPayrollItem.where(import_origin: nil).where("import_source LIKE ?", "time_tracking:%").in_batches(of: BATCH_SIZE) do |batch|
      batch.update_all(import_origin: "time_tracking")
    end

    MigrationPayrollItem.where(import_origin: nil, import_source: "timecard_ocr").in_batches(of: BATCH_SIZE) do |batch|
      batch.update_all(import_origin: "timecard_ocr")
    end

    after_counts = MigrationPayrollItem.group(:import_source, :import_origin).count
    say "payroll_items row counts by [import_source, import_origin] after backfill: #{after_counts.inspect}"
  end

  def backfill_payroll_imports_import_origin!
    MigrationPayrollImport.where("import_origin = '{}'::jsonb").in_batches(of: 500) do |batch|
      records = batch.to_a
      session_ids = records.filter_map(&:payroll_intake_session_id).uniq
      sessions = session_ids.any? ? MigrationIntakeSession.where(id: session_ids).index_by(&:id) : {}

      superseded_ids = sessions.values.filter_map(&:supersedes_id).uniq
      superseded_package_ids = superseded_ids.any? ? MigrationIntakeSession.where(id: superseded_ids).pluck(:id, :package_id).to_h : {}

      import_ids = records.map(&:id)
      submission_links = MigrationSubmissionImport.where(payroll_import_id: import_ids)
                                                  .order(:id)
                                                  .each_with_object({}) { |link, acc| acc[link.payroll_import_id] = link }
      submission_ids = submission_links.values.map(&:payroll_submission_id).uniq
      submissions = submission_ids.any? ? MigrationSubmission.where(id: submission_ids).index_by(&:id) : {}

      records.each do |record|
        session = sessions[record.payroll_intake_session_id]
        link = submission_links[record.id]
        submission = link && submissions[link.payroll_submission_id]
        raw = record.raw_data.is_a?(Hash) ? record.raw_data : {}

        origin = {
          "adapter_key" => session&.source_type || "mosa_revel",
          "parser_version" => session&.parser_version || "legacy",
          "channel" => submission ? "portal_revision" : "staff_upload",
          "package_id" => session&.package_id,
          "package_revision" => session&.package_revision,
          "reimport" => session&.supersedes_id.present? || false,
          "supersedes_package_id" => session&.supersedes_id && superseded_package_ids[session.supersedes_id],
          "portal_submission_id" => submission&.id,
          "portal_revision" => submission&.revision,
          "replaced_hand_edited_hours" => Array(raw["replaced_hand_edited_hours"]).any?,
          "backfilled" => true
        }.compact

        MigrationPayrollImport.where(id: record.id, import_origin: {}).update_all(import_origin: origin)
      end
    end
  end

  def replace_bonus_source_constraint!(sources, temporary_name)
    current = connection.check_constraints(:payroll_items).find { |c| c.name == BONUS_SOURCE_CONSTRAINT }
    return unless current

    if constraint_values(current) == sources.sort
      validate_check_constraint :payroll_items, name: BONUS_SOURCE_CONSTRAINT unless current.validate?
      with_lock_timeout { remove_temporary_bonus_constraints! }
      return
    end

    temporary = connection.check_constraints(:payroll_items).find { |c| c.name == temporary_name }
    unless temporary
      with_lock_timeout do
        add_check_constraint :payroll_items,
                             "bonus_source IS NULL OR bonus_source IN (#{quoted_list(sources)})",
                             name: temporary_name,
                             validate: false
      end
    end

    validate_check_constraint :payroll_items, name: temporary_name

    with_lock_timeout do
      remove_temporary_bonus_constraints!(except: temporary_name)
      remove_check_constraint :payroll_items, name: BONUS_SOURCE_CONSTRAINT
      execute "ALTER TABLE payroll_items RENAME CONSTRAINT #{connection.quote_column_name(temporary_name)} TO #{connection.quote_column_name(BONUS_SOURCE_CONSTRAINT)}"
    end
  end

  def remove_temporary_bonus_constraints!(except: nil)
    [ BONUS_SOURCE_EXPANDED_TMP, BONUS_SOURCE_ORIGINAL_TMP ].each do |name|
      next if name == except
      next unless connection.check_constraint_exists?(:payroll_items, name: name)

      remove_check_constraint :payroll_items, name: name
    end
  end

  def constraint_values(constraint)
    constraint.expression.scan(/'([^']+)'/).flatten.sort
  end
end
