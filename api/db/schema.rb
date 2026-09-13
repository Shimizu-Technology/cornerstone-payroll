# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_13_080000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "aire_payroll_acknowledgements", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.datetime "enqueued_at"
    t.string "event_id", null: false
    t.text "last_error"
    t.datetime "occurred_at", null: false
    t.string "status", null: false
    t.bigint "time_tracking_import_id", null: false
    t.datetime "updated_at", null: false
    t.index ["delivered_at", "enqueued_at"], name: "idx_aire_payroll_acknowledgements_dispatch"
    t.index ["event_id"], name: "index_aire_payroll_acknowledgements_on_event_id", unique: true
    t.index ["time_tracking_import_id"], name: "index_aire_payroll_acknowledgements_on_time_tracking_import_id"
    t.check_constraint "status::text = ANY (ARRAY['imported'::character varying::text, 'committed'::character varying::text, 'payment_issued'::character varying::text, 'payment_failed'::character varying::text])", name: "aire_payroll_acknowledgements_status_check"
  end

  create_table "aire_payroll_entry_acknowledgements", force: :cascade do |t|
    t.bigint "check_event_id"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.datetime "enqueued_at"
    t.string "event_id", null: false
    t.text "last_error"
    t.datetime "occurred_at", null: false
    t.string "payment_method"
    t.string "payment_reference"
    t.bigint "payroll_item_id", null: false
    t.string "source_event_key", null: false
    t.string "source_time_entry_id", null: false
    t.string "source_user_id", null: false
    t.uuid "source_user_uuid"
    t.string "status", null: false
    t.bigint "time_tracking_import_id", null: false
    t.datetime "updated_at", null: false
    t.index ["check_event_id"], name: "index_aire_payroll_entry_acknowledgements_on_check_event_id"
    t.index ["delivered_at", "enqueued_at"], name: "idx_aire_entry_ack_dispatch"
    t.index ["event_id"], name: "index_aire_payroll_entry_acknowledgements_on_event_id", unique: true
    t.index ["payroll_item_id"], name: "index_aire_payroll_entry_acknowledgements_on_payroll_item_id"
    t.index ["source_event_key"], name: "idx_aire_entry_ack_unique_source_event", unique: true
    t.index ["time_tracking_import_id"], name: "idx_on_time_tracking_import_id_95ff82b3b6"
    t.check_constraint "status::text = ANY (ARRAY['imported'::character varying::text, 'committed'::character varying::text, 'payment_prepared'::character varying::text, 'payment_issued'::character varying::text, 'payment_failed'::character varying::text, 'payment_voided'::character varying::text])", name: "aire_payroll_entry_ack_status_check"
  end

  create_table "annual_retirement_limits", force: :cascade do |t|
    t.decimal "catch_up_limit", precision: 14, scale: 2, null: false
    t.datetime "created_at", null: false
    t.decimal "elective_deferral_limit", precision: 14, scale: 2, null: false
    t.decimal "enhanced_catch_up_limit", precision: 14, scale: 2, null: false
    t.decimal "roth_catch_up_wage_threshold", precision: 14, scale: 2, null: false
    t.string "source_name", null: false
    t.string "source_url", null: false
    t.integer "tax_year", null: false
    t.datetime "updated_at", null: false
    t.index ["tax_year"], name: "index_annual_retirement_limits_on_tax_year", unique: true
  end

  create_table "annual_tax_configs", force: :cascade do |t|
    t.decimal "additional_medicare_rate", precision: 6, scale: 5, default: "0.009", null: false
    t.decimal "additional_medicare_threshold", precision: 12, scale: 2, default: "200000.0", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.boolean "is_active", default: false, null: false
    t.decimal "medicare_rate", precision: 6, scale: 5, default: "0.0145", null: false
    t.decimal "ss_rate", precision: 6, scale: 5, default: "0.062", null: false
    t.decimal "ss_wage_base", precision: 12, scale: 2, null: false
    t.integer "tax_year", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["is_active"], name: "index_annual_tax_configs_on_is_active"
    t.index ["tax_year"], name: "index_annual_tax_configs_on_tax_year", unique: true
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.string "actor_email"
    t.string "actor_name"
    t.string "actor_role"
    t.bigint "company_id"
    t.datetime "created_at", null: false
    t.string "event_category", default: "activity", null: false
    t.string "ip_address"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id"
    t.bigint "record_id"
    t.string "record_type"
    t.string "request_id"
    t.string "subject_name"
    t.string "user_agent"
    t.bigint "user_id"
    t.index ["company_id"], name: "index_audit_logs_on_company_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["organization_id", "created_at", "id"], name: "idx_audit_logs_org_history"
    t.index ["organization_id", "record_type", "record_id"], name: "idx_audit_logs_org_subject"
    t.index ["organization_id"], name: "index_audit_logs_on_organization_id"
    t.index ["record_type", "record_id"], name: "index_audit_logs_on_record_type_and_record_id"
    t.index ["request_id"], name: "index_audit_logs_on_request_id"
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
  end

  create_table "cable_connection_tickets", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.bigint "user_id", null: false
    t.index ["company_id"], name: "index_cable_connection_tickets_on_company_id"
    t.index ["expires_at", "used_at"], name: "index_cable_connection_tickets_on_expires_at_and_used_at"
    t.index ["token_digest"], name: "index_cable_connection_tickets_on_token_digest", unique: true
    t.index ["user_id"], name: "index_cable_connection_tickets_on_user_id"
  end

  create_table "check_events", force: :cascade do |t|
    t.string "check_number", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "ip_address"
    t.bigint "payroll_item_id", null: false
    t.string "reason"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["check_number"], name: "index_check_events_on_check_number"
    t.index ["event_type"], name: "index_check_events_on_event_type"
    t.index ["payroll_item_id", "event_type"], name: "index_check_events_on_payroll_item_id_and_event_type"
    t.index ["payroll_item_id"], name: "index_check_events_on_payroll_item_id"
    t.index ["user_id"], name: "index_check_events_on_user_id"
  end

  create_table "check_print_runs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "check_stock_type", null: false
    t.bigint "company_id", null: false
    t.datetime "confirmed_at"
    t.bigint "confirmed_by_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "filename", null: false
    t.datetime "generated_at", null: false
    t.jsonb "manifest", default: [], null: false
    t.bigint "pay_period_id", null: false
    t.integer "selected_count", null: false
    t.string "sha256", null: false
    t.integer "starting_slot", default: 1, null: false
    t.string "status", default: "generated", null: false
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_check_print_runs_on_company_id"
    t.index ["confirmed_by_id"], name: "index_check_print_runs_on_confirmed_by_id"
    t.index ["created_by_id"], name: "index_check_print_runs_on_created_by_id"
    t.index ["pay_period_id", "generated_at"], name: "idx_check_print_runs_period_generated"
    t.index ["pay_period_id"], name: "index_check_print_runs_on_pay_period_id"
    t.index ["storage_key"], name: "index_check_print_runs_on_storage_key", unique: true
    t.check_constraint "byte_size > 0", name: "check_print_runs_byte_size_check"
    t.check_constraint "selected_count > 0", name: "check_print_runs_selected_count_check"
    t.check_constraint "starting_slot >= 1 AND starting_slot <= 4", name: "check_print_runs_starting_slot_check"
    t.check_constraint "status::text = ANY (ARRAY['generated'::character varying::text, 'confirmed'::character varying::text])", name: "check_print_runs_status_check"
  end

  create_table "check_signoff_sheets", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "entries", default: []
    t.datetime "generated_at"
    t.jsonb "notes", default: []
    t.bigint "pay_period_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["company_id"], name: "index_check_signoff_sheets_on_company_id"
    t.index ["pay_period_id"], name: "index_check_signoff_sheets_on_pay_period_id", unique: true
    t.index ["updated_by_id"], name: "index_check_signoff_sheets_on_updated_by_id"
  end

  create_table "client_documents", force: :cascade do |t|
    t.string "category", null: false
    t.bigint "company_id", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id"
    t.string "file_key", null: false
    t.string "file_name", null: false
    t.bigint "file_size", default: 0, null: false
    t.text "notes"
    t.string "preview_content_type"
    t.text "preview_error"
    t.string "preview_file_key"
    t.datetime "preview_generated_at"
    t.string "preview_status", default: "pending", null: false
    t.boolean "shared_by_staff", default: false, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "uploaded_by_id"
    t.boolean "visible_to_client", default: true, null: false
    t.index ["company_id", "category"], name: "index_client_documents_on_company_id_and_category"
    t.index ["company_id", "created_at"], name: "index_client_documents_on_company_id_and_created_at"
    t.index ["company_id", "preview_status"], name: "index_client_documents_on_company_id_and_preview_status"
    t.index ["company_id", "visible_to_client"], name: "index_client_documents_on_company_and_client_visibility"
    t.index ["company_id"], name: "index_client_documents_on_company_id"
    t.index ["employee_id"], name: "index_client_documents_on_employee_id"
    t.index ["file_key"], name: "index_client_documents_on_file_key", unique: true
    t.index ["id", "company_id"], name: "idx_client_documents_readiness_tenant_key", unique: true
    t.index ["uploaded_by_id"], name: "index_client_documents_on_uploaded_by_id"
  end

  create_table "client_portal_messages", force: :cascade do |t|
    t.bigint "author_id"
    t.text "body"
    t.bigint "client_document_id"
    t.bigint "client_portal_thread_id", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_client_portal_messages_on_author_id"
    t.index ["client_document_id"], name: "index_client_portal_messages_on_client_document_id"
    t.index ["client_portal_thread_id"], name: "index_client_portal_messages_on_thread_id"
    t.index ["company_id", "created_at"], name: "index_client_portal_messages_on_company_created_at"
    t.index ["company_id"], name: "index_client_portal_messages_on_company_id"
  end

  create_table "client_portal_threads", force: :cascade do |t|
    t.datetime "client_last_read_at"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "last_message_at"
    t.datetime "resolved_at"
    t.bigint "resolved_by_id"
    t.datetime "staff_last_read_at"
    t.string "status", default: "open", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status", "last_message_at"], name: "index_client_portal_threads_on_company_status_last_message"
    t.index ["company_id"], name: "index_client_portal_threads_on_company_id"
    t.index ["created_by_id"], name: "index_client_portal_threads_on_created_by_id"
    t.index ["resolved_by_id"], name: "index_client_portal_threads_on_resolved_by_id"
  end

  create_table "companies", force: :cascade do |t|
    t.boolean "active", default: true
    t.bigint "active_printer_profile_id"
    t.string "address_line1"
    t.string "address_line2"
    t.boolean "auto_create_fit_check", default: false, null: false
    t.string "bank_address"
    t.string "bank_name"
    t.jsonb "check_layout_config", default: {}, null: false
    t.string "check_memo_template"
    t.decimal "check_offset_x", precision: 5, scale: 3, default: "0.0", null: false
    t.decimal "check_offset_y", precision: 5, scale: 3, default: "0.0", null: false
    t.string "check_stock_type", default: "bottom_check", null: false
    t.string "city"
    t.boolean "client_payroll_approval_required", default: false, null: false
    t.datetime "created_at", null: false
    t.string "ein"
    t.string "email"
    t.boolean "historical_payroll_enabled", default: false, null: false
    t.datetime "migration_rehearsal_completed_at"
    t.datetime "migration_rehearsal_created_at"
    t.bigint "migration_rehearsal_created_by_id"
    t.text "migration_rehearsal_error"
    t.string "migration_rehearsal_status"
    t.bigint "migration_source_batch_id"
    t.bigint "migration_source_company_id"
    t.string "name", null: false
    t.integer "next_check_number", default: 1001, null: false
    t.bigint "organization_id", null: false
    t.string "pay_frequency", default: "biweekly"
    t.string "payroll_environment", default: "live", null: false
    t.jsonb "payroll_intake_source_types", default: [], null: false
    t.string "phone"
    t.boolean "simple_payroll_register_enabled", default: false, null: false
    t.string "state"
    t.datetime "updated_at", null: false
    t.string "zip"
    t.index ["active_printer_profile_id"], name: "index_companies_on_active_printer_profile_id"
    t.index ["ein"], name: "index_live_companies_on_ein", unique: true, where: "((payroll_environment)::text = 'live'::text)"
    t.index ["migration_rehearsal_created_by_id"], name: "index_companies_on_migration_rehearsal_created_by_id"
    t.index ["migration_source_batch_id"], name: "index_companies_on_migration_source_batch_id"
    t.index ["migration_source_company_id", "active"], name: "idx_companies_active_migration_rehearsals", unique: true, where: "(((payroll_environment)::text = 'migration_rehearsal'::text) AND (active = true))"
    t.index ["migration_source_company_id"], name: "index_companies_on_migration_source_company_id"
    t.index ["name"], name: "index_companies_on_name"
    t.index ["organization_id"], name: "index_companies_on_organization_id"
    t.check_constraint "migration_rehearsal_status IS NULL OR (migration_rehearsal_status::text = ANY (ARRAY['pending'::character varying::text, 'ready'::character varying::text, 'failed'::character varying::text]))", name: "companies_migration_rehearsal_status_check"
    t.check_constraint "payroll_environment::text = 'live'::text AND migration_source_company_id IS NULL AND migration_source_batch_id IS NULL AND migration_rehearsal_status IS NULL OR payroll_environment::text = 'migration_rehearsal'::text AND migration_source_company_id IS NOT NULL AND migration_source_batch_id IS NOT NULL AND migration_rehearsal_status IS NOT NULL", name: "companies_migration_rehearsal_shape_check"
    t.check_constraint "payroll_environment::text = ANY (ARRAY['live'::character varying::text, 'migration_rehearsal'::character varying::text])", name: "companies_payroll_environment_check"
  end

  create_table "company_assignments", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["company_id"], name: "index_company_assignments_on_company_id"
    t.index ["user_id", "company_id"], name: "index_company_assignments_on_user_id_and_company_id", unique: true
    t.index ["user_id"], name: "index_company_assignments_on_user_id"
  end

  create_table "company_pay_schedules", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "confirmation_status", default: "needs_confirmation", null: false
    t.datetime "confirmed_at"
    t.bigint "confirmed_by_id"
    t.datetime "created_at", null: false
    t.date "effective_on", null: false
    t.date "ends_on"
    t.string "frequency", null: false
    t.text "notes"
    t.integer "pay_date_offset_days"
    t.string "pay_date_rule", default: "manual", null: false
    t.date "period_anchor_date"
    t.string "period_rule", default: "manual", null: false
    t.integer "period_start_weekday"
    t.string "source", default: "legacy_system_default", null: false
    t.string "timezone", default: "Pacific/Guam", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "effective_on"], name: "idx_company_pay_schedules_effective", unique: true
    t.index ["company_id"], name: "idx_company_pay_schedules_one_current", unique: true, where: "(ends_on IS NULL)"
    t.index ["company_id"], name: "index_company_pay_schedules_on_company_id"
    t.index ["confirmed_by_id"], name: "index_company_pay_schedules_on_confirmed_by_id"
    t.check_constraint "confirmation_status::text = ANY (ARRAY['confirmed'::character varying::text, 'needs_confirmation'::character varying::text])", name: "company_pay_schedules_confirmation_check"
    t.check_constraint "ends_on IS NULL OR ends_on >= effective_on", name: "company_pay_schedules_dates_check"
    t.check_constraint "frequency::text = ANY (ARRAY['weekly'::character varying::text, 'biweekly'::character varying::text, 'semimonthly'::character varying::text, 'monthly'::character varying::text])", name: "company_pay_schedules_frequency_check"
    t.check_constraint "pay_date_rule::text = ANY (ARRAY['manual'::character varying::text, 'days_after_period_end'::character varying::text])", name: "company_pay_schedules_pay_date_rule_check"
    t.check_constraint "period_anchor_date IS NULL OR period_start_weekday IS NULL OR EXTRACT(dow FROM period_anchor_date)::integer = period_start_weekday", name: "company_pay_schedules_anchor_weekday_check"
    t.check_constraint "period_rule::text <> 'biweekly'::text OR period_anchor_date IS NOT NULL", name: "company_pay_schedules_biweekly_anchor_check"
    t.check_constraint "period_rule::text = ANY (ARRAY['manual'::character varying::text, 'weekly'::character varying::text, 'biweekly'::character varying::text, 'semimonthly'::character varying::text])", name: "company_pay_schedules_period_rule_check"
    t.check_constraint "period_start_weekday IS NULL OR period_start_weekday >= 0 AND period_start_weekday <= 6", name: "company_pay_schedules_weekday_check"
    t.check_constraint "source::text = ANY (ARRAY['operator_confirmed'::character varying::text, 'production_inferred'::character varying::text, 'legacy_system_default'::character varying::text])", name: "company_pay_schedules_source_check"
  end

  create_table "company_workweeks", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "confirmation_status", default: "needs_confirmation", null: false
    t.datetime "confirmed_at"
    t.bigint "confirmed_by_id"
    t.datetime "created_at", null: false
    t.date "effective_on", null: false
    t.date "ends_on"
    t.text "notes"
    t.string "source", default: "legacy_system_default", null: false
    t.integer "starts_at_minutes", default: 0, null: false
    t.integer "starts_on_weekday", default: 0, null: false
    t.string "timezone", default: "Pacific/Guam", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "effective_on"], name: "idx_company_workweeks_effective", unique: true
    t.index ["company_id"], name: "idx_company_workweeks_one_current", unique: true, where: "(ends_on IS NULL)"
    t.index ["company_id"], name: "index_company_workweeks_on_company_id"
    t.index ["confirmed_by_id"], name: "index_company_workweeks_on_confirmed_by_id"
    t.check_constraint "confirmation_status::text = ANY (ARRAY['confirmed'::character varying::text, 'needs_confirmation'::character varying::text])", name: "company_workweeks_confirmation_check"
    t.check_constraint "ends_on IS NULL OR ends_on >= effective_on", name: "company_workweeks_dates_check"
    t.check_constraint "source::text = ANY (ARRAY['operator_confirmed'::character varying::text, 'production_inferred'::character varying::text, 'legacy_system_default'::character varying::text])", name: "company_workweeks_source_check"
    t.check_constraint "starts_at_minutes >= 0 AND starts_at_minutes <= 1439", name: "company_workweeks_time_check"
    t.check_constraint "starts_on_weekday >= 0 AND starts_on_weekday <= 6", name: "company_workweeks_weekday_check"
  end

  create_table "company_ytd_totals", force: :cascade do |t|
    t.integer "active_employees", default: 0
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.decimal "employer_medicare", precision: 16, scale: 2, default: "0.0"
    t.decimal "employer_social_security", precision: 16, scale: 2, default: "0.0"
    t.decimal "gross_pay", precision: 16, scale: 2, default: "0.0"
    t.decimal "medicare_tax", precision: 16, scale: 2, default: "0.0"
    t.decimal "net_pay", precision: 16, scale: 2, default: "0.0"
    t.decimal "social_security_tax", precision: 16, scale: 2, default: "0.0"
    t.integer "total_employees", default: 0
    t.datetime "updated_at", null: false
    t.decimal "withholding_tax", precision: 16, scale: 2, default: "0.0"
    t.integer "year", null: false
    t.index ["company_id", "year"], name: "index_company_ytd_totals_on_company_id_and_year", unique: true
    t.index ["company_id"], name: "index_company_ytd_totals_on_company_id"
  end

  create_table "daily_time_records", force: :cascade do |t|
    t.decimal "actual_worked_hours", precision: 6, scale: 2
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.bigint "employee_work_profile_id"
    t.text "exception_reason"
    t.decimal "holiday_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.string "ledger_key", default: "authoritative", null: false
    t.text "override_reason"
    t.decimal "pto_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.integer "revision", default: 1, null: false
    t.decimal "scheduled_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.string "source", null: false
    t.datetime "superseded_at"
    t.bigint "supersedes_id"
    t.datetime "updated_at", null: false
    t.date "work_date", null: false
    t.date "workweek_started_on", null: false
    t.index ["company_id"], name: "index_daily_time_records_on_company_id"
    t.index ["employee_id", "work_date", "ledger_key"], name: "idx_daily_time_records_current_day", unique: true, where: "(superseded_at IS NULL)"
    t.index ["employee_id", "workweek_started_on", "ledger_key"], name: "idx_daily_time_records_workweek"
    t.index ["employee_id"], name: "index_daily_time_records_on_employee_id"
    t.index ["employee_work_profile_id"], name: "index_daily_time_records_on_employee_work_profile_id"
    t.index ["supersedes_id"], name: "index_daily_time_records_on_supersedes_id"
    t.check_constraint "ledger_key::text = ANY (ARRAY['authoritative'::character varying::text, 'parallel'::character varying::text, 'test'::character varying::text, 'historical'::character varying::text])", name: "daily_time_records_ledger_check"
    t.check_constraint "scheduled_hours >= 0::numeric AND scheduled_hours <= 24::numeric AND (actual_worked_hours IS NULL OR actual_worked_hours >= 0::numeric AND actual_worked_hours <= 24::numeric) AND pto_hours >= 0::numeric AND holiday_hours >= 0::numeric", name: "daily_time_records_hours_check"
    t.check_constraint "source::text = ANY (ARRAY['schedule'::character varying::text, 'import'::character varying::text, 'manual'::character varying::text, 'correction_reference'::character varying::text, 'production_backfill'::character varying::text])", name: "daily_time_records_source_check"
  end

  create_table "deduction_types", force: :cascade do |t|
    t.boolean "active", default: true
    t.string "category", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.decimal "default_amount", precision: 10, scale: 2
    t.boolean "generates_check", default: false, null: false
    t.boolean "is_percentage", default: false
    t.string "name", null: false
    t.string "payee_name"
    t.string "reference_number"
    t.string "reporting_group"
    t.string "sub_category"
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_deduction_types_on_category"
    t.index ["company_id", "name"], name: "index_deduction_types_on_company_id_and_name", unique: true
    t.index ["company_id", "reporting_group"], name: "idx_deduction_types_company_reporting_group"
    t.index ["company_id", "sub_category"], name: "index_deduction_types_on_company_id_and_sub_category"
    t.index ["company_id"], name: "index_deduction_types_on_company_id"
  end

  create_table "department_ytd_totals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "department_id", null: false
    t.decimal "gross_pay", precision: 16, scale: 2, default: "0.0"
    t.decimal "medicare_tax", precision: 16, scale: 2, default: "0.0"
    t.decimal "net_pay", precision: 16, scale: 2, default: "0.0"
    t.decimal "social_security_tax", precision: 16, scale: 2, default: "0.0"
    t.integer "total_employees", default: 0
    t.datetime "updated_at", null: false
    t.decimal "withholding_tax", precision: 16, scale: 2, default: "0.0"
    t.integer "year", null: false
    t.index ["department_id", "year"], name: "index_department_ytd_totals_on_department_id_and_year", unique: true
    t.index ["department_id"], name: "index_department_ytd_totals_on_department_id"
  end

  create_table "departments", force: :cascade do |t|
    t.boolean "active", default: true
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "name"], name: "index_departments_on_company_id_and_name", unique: true
    t.index ["company_id"], name: "index_departments_on_company_id"
  end

  create_table "employee_change_requests", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "direct_changes_applied", default: {}, null: false
    t.bigint "employee_id", null: false
    t.jsonb "original_values", default: {}, null: false
    t.jsonb "proposed_changes", default: {}, null: false
    t.string "request_kind", default: "update", null: false
    t.text "request_notes"
    t.bigint "requested_by_id"
    t.text "review_notes"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.text "sensitive_payload_encrypted"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status"], name: "index_employee_change_requests_on_company_id_and_status"
    t.index ["company_id"], name: "index_employee_change_requests_on_company_id"
    t.index ["employee_id", "created_at"], name: "index_employee_change_requests_on_employee_id_and_created_at"
    t.index ["employee_id"], name: "idx_employee_change_requests_one_pending", unique: true, where: "(status = 0)"
    t.index ["employee_id"], name: "index_employee_change_requests_on_employee_id"
    t.index ["requested_by_id"], name: "index_employee_change_requests_on_requested_by_id"
    t.index ["reviewed_by_id"], name: "index_employee_change_requests_on_reviewed_by_id"
    t.check_constraint "request_kind::text = ANY (ARRAY['create'::character varying::text, 'update'::character varying::text])", name: "employee_change_requests_kind_check"
  end

  create_table "employee_configuration_review_resolutions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.string "item_code", null: false
    t.jsonb "item_fields", default: [], null: false
    t.text "item_message", null: false
    t.text "resolution_note", null: false
    t.datetime "reviewed_at", null: false
    t.bigint "reviewed_by_id"
    t.string "reviewed_by_email", null: false
    t.string "reviewed_by_name", null: false
    t.string "reviewed_by_role", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "reviewed_at"], name: "idx_employee_configuration_review_resolutions_company_time"
    t.index ["company_id"], name: "index_employee_configuration_review_resolutions_on_company_id"
    t.index ["employee_id", "item_code"], name: "idx_employee_configuration_review_resolutions_unique", unique: true
    t.index ["employee_id"], name: "index_employee_configuration_review_resolutions_on_employee_id"
    t.index ["reviewed_by_id"], name: "idx_employee_config_reviews_reviewer"
    t.check_constraint "jsonb_typeof(item_fields) = 'array'::text", name: "employee_configuration_review_resolutions_fields_array"
  end

  create_table "employee_deductions", force: :cascade do |t|
    t.boolean "active", default: true
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.datetime "created_at", null: false
    t.bigint "deduction_type_id", null: false
    t.bigint "employee_id", null: false
    t.boolean "is_percentage", default: false
    t.datetime "updated_at", null: false
    t.index ["deduction_type_id"], name: "index_employee_deductions_on_deduction_type_id"
    t.index ["employee_id", "deduction_type_id"], name: "idx_employee_deductions_unique", unique: true
    t.index ["employee_id"], name: "index_employee_deductions_on_employee_id"
  end

  create_table "employee_document_requirement_events", force: :cascade do |t|
    t.bigint "actor_id"
    t.bigint "client_document_id"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "document_title"
    t.bigint "employee_document_requirement_id", null: false
    t.bigint "employee_id", null: false
    t.string "event_type", null: false
    t.string "from_status"
    t.text "note"
    t.string "to_status", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_employee_document_requirement_events_on_actor_id"
    t.index ["client_document_id"], name: "idx_on_client_document_id_96591a9515"
    t.index ["company_id"], name: "index_employee_document_requirement_events_on_company_id"
    t.index ["employee_document_requirement_id", "created_at"], name: "index_employee_document_requirement_events_on_history"
    t.index ["employee_document_requirement_id"], name: "idx_on_employee_document_requirement_id_04b47c5045"
    t.index ["employee_id"], name: "index_employee_document_requirement_events_on_employee_id"
  end

  execute <<~SQL
    CREATE OR REPLACE FUNCTION prevent_employee_document_requirement_event_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION 'employee_document_requirement_events are append-only'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $function$;

    CREATE TRIGGER employee_document_requirement_events_append_only
    BEFORE UPDATE OR DELETE ON employee_document_requirement_events
    FOR EACH ROW
    EXECUTE FUNCTION prevent_employee_document_requirement_event_mutation();
  SQL

  create_table "employee_document_requirements", force: :cascade do |t|
    t.bigint "client_document_id"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.date "due_on"
    t.bigint "employee_id", null: false
    t.string "label", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "received_at"
    t.boolean "required_for_payroll", default: true, null: false
    t.string "requirement_type", null: false
    t.text "review_note"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.string "status", default: "missing", null: false
    t.datetime "updated_at", null: false
    t.index ["client_document_id"], name: "index_employee_document_requirements_on_client_document_id"
    t.index ["company_id", "status"], name: "index_employee_document_requirements_on_company_and_status"
    t.index ["company_id"], name: "index_employee_document_requirements_on_company_id"
    t.index ["created_by_id"], name: "index_employee_document_requirements_on_created_by_id"
    t.index ["employee_id", "requirement_type"], name: "index_employee_document_requirements_on_employee_and_type", unique: true
    t.index ["employee_id"], name: "index_employee_document_requirements_on_employee_id"
    t.index ["id", "company_id"], name: "idx_employee_document_requirements_tenant_key", unique: true
    t.index ["reviewed_by_id"], name: "index_employee_document_requirements_on_reviewed_by_id"
  end

  create_table "employee_loans", force: :cascade do |t|
    t.date "balance_as_of"
    t.string "balance_source"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.decimal "current_balance", precision: 10, scale: 2, default: "0.0"
    t.bigint "deduction_type_id"
    t.bigint "employee_id", null: false
    t.date "first_deduction_date"
    t.string "name", null: false
    t.text "notes"
    t.decimal "opening_balance", precision: 10, scale: 2
    t.decimal "original_amount", precision: 10, scale: 2
    t.date "paid_off_date"
    t.decimal "payment_amount", precision: 10, scale: 2
    t.boolean "principal_amount_known", default: true, null: false
    t.date "start_date"
    t.string "status", default: "active", null: false
    t.datetime "stopped_at"
    t.bigint "stopped_by_id"
    t.string "tracking_mode", default: "balance_tracked", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status"], name: "index_employee_loans_on_company_id_and_status"
    t.index ["company_id"], name: "index_employee_loans_on_company_id"
    t.index ["created_by_id"], name: "index_employee_loans_on_created_by_id"
    t.index ["deduction_type_id"], name: "index_employee_loans_on_deduction_type_id"
    t.index [ "employee_id", "deduction_type_id" ], name: "idx_employee_loans_unique_deduction", unique: true, where: "(deduction_type_id IS NOT NULL)"
    t.index ["employee_id", "status"], name: "index_employee_loans_on_employee_id_and_status"
    t.index ["employee_id"], name: "index_employee_loans_on_employee_id"
    t.index ["stopped_by_id"], name: "index_employee_loans_on_stopped_by_id"
    t.check_constraint "balance_source::text = ANY (ARRAY['new_loan'::character varying::text, 'quickbooks'::character varying::text, 'statement'::character varying::text, 'employee_confirmation'::character varying::text, 'other_verified'::character varying::text])", name: "employee_loans_balance_source_check"
    t.check_constraint "status::text = 'stopped'::text AND stopped_at IS NOT NULL OR status::text <> 'stopped'::text AND stopped_at IS NULL", name: "employee_loans_stopped_shape"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'paid_off'::character varying::text, 'suspended'::character varying::text, 'stopped'::character varying::text])", name: "employee_loans_status_check"
    t.check_constraint "tracking_mode::text = 'balance_tracked'::text AND original_amount IS NOT NULL AND original_amount > 0::numeric AND opening_balance IS NOT NULL AND opening_balance > 0::numeric AND current_balance IS NOT NULL AND current_balance >= 0::numeric AND balance_as_of IS NOT NULL AND balance_source IS NOT NULL AND status::text <> 'stopped'::text OR tracking_mode::text = 'recurring_no_balance'::text AND original_amount IS NULL AND opening_balance IS NULL AND current_balance IS NULL AND balance_as_of IS NULL AND balance_source IS NULL AND principal_amount_known = false AND status::text <> 'paid_off'::text", name: "employee_loans_tracking_shape"
    t.check_constraint "tracking_mode::text = ANY (ARRAY['balance_tracked'::character varying::text, 'recurring_no_balance'::character varying::text])", name: "employee_loans_tracking_mode_check"
  end

  create_table "employee_payroll_fields", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.decimal "amount", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.bigint "employee_loan_id"
    t.date "end_date"
    t.text "notes"
    t.bigint "payroll_field_definition_id", null: false
    t.decimal "percentage", precision: 8, scale: 4
    t.date "start_date"
    t.datetime "updated_at", null: false
    t.index ["employee_id", "active"], name: "idx_employee_payroll_fields_employee_active"
    t.index ["employee_id", "payroll_field_definition_id"], name: "idx_employee_payroll_fields_unique", unique: true
    t.index ["employee_id"], name: "index_employee_payroll_fields_on_employee_id"
    t.index [ "employee_loan_id" ], name: "idx_employee_fields_unique_loan", unique: true, where: "(employee_loan_id IS NOT NULL)"
    t.index ["employee_loan_id"], name: "index_employee_payroll_fields_on_employee_loan_id"
    t.index ["payroll_field_definition_id"], name: "idx_employee_payroll_fields_definition"
  end

  create_table "employee_retirement_elections", force: :cascade do |t|
    t.boolean "catch_up_enabled", default: false, null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.date "effective_on", null: false
    t.boolean "eligible", default: true, null: false
    t.string "eligible_compensation", default: "gross_wages", null: false
    t.bigint "employee_id", null: false
    t.decimal "employer_match_annual_cap", precision: 14, scale: 2
    t.decimal "employer_match_deferral_cap_rate", precision: 8, scale: 6
    t.string "employer_match_destination", default: "traditional", null: false
    t.string "employer_match_mode", default: "none", null: false
    t.decimal "employer_match_period_cap", precision: 14, scale: 2
    t.decimal "employer_match_rate", precision: 8, scale: 6, default: "0.0", null: false
    t.decimal "employer_match_ytd_before_system", precision: 14, scale: 2, default: "0.0", null: false
    t.string "limit_priority", default: "proportional", null: false
    t.boolean "participating", default: false, null: false
    t.decimal "plan_annual_employee_limit", precision: 14, scale: 2
    t.string "plan_name", default: "401(k)", null: false
    t.text "reason", null: false
    t.decimal "roth_amount", precision: 14, scale: 2, default: "0.0", null: false
    t.string "roth_contribution_type", default: "percentage", null: false
    t.decimal "roth_rate", precision: 8, scale: 6, default: "0.0", null: false
    t.string "source", null: false
    t.decimal "traditional_amount", precision: 14, scale: 2, default: "0.0", null: false
    t.string "traditional_contribution_type", default: "percentage", null: false
    t.decimal "traditional_rate", precision: 8, scale: 6, default: "0.0", null: false
    t.string "true_up_policy", default: "none", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_employee_retirement_elections_on_company_id"
    t.index ["created_by_id"], name: "index_employee_retirement_elections_on_created_by_id"
    t.index ["employee_id", "effective_on"], name: "idx_employee_retirement_elections_effective", unique: true
    t.index ["employee_id"], name: "index_employee_retirement_elections_on_employee_id"
    t.check_constraint "(employer_match_destination::text = ANY (ARRAY['traditional'::character varying, 'roth'::character varying]::text[])) AND (true_up_policy::text = ANY (ARRAY['none'::character varying, 'year_to_date'::character varying]::text[]))", name: "retirement_elections_match_policy"
    t.check_constraint "(traditional_contribution_type::text = ANY (ARRAY['percentage'::character varying, 'fixed'::character varying]::text[])) AND (roth_contribution_type::text = ANY (ARRAY['percentage'::character varying, 'fixed'::character varying]::text[]))", name: "retirement_elections_contribution_types"
    t.check_constraint "eligible_compensation::text = ANY (ARRAY['gross_wages'::character varying, 'gross_excluding_tips'::character varying, 'base_pay'::character varying]::text[])", name: "retirement_elections_compensation"
    t.check_constraint "employer_match_mode::text = ANY (ARRAY['none'::character varying, 'compensation_percentage'::character varying, 'employee_deferral_percentage'::character varying]::text[])", name: "retirement_elections_match_mode"
    t.check_constraint "limit_priority::text = ANY (ARRAY['proportional'::character varying, 'traditional_first'::character varying, 'roth_first'::character varying]::text[])", name: "retirement_elections_limit_priority"
    t.check_constraint "participating = false OR eligible = true", name: "retirement_elections_participation_eligibility"
    t.check_constraint "traditional_amount >= 0::numeric AND roth_amount >= 0::numeric AND employer_match_ytd_before_system >= 0::numeric AND (plan_annual_employee_limit IS NULL OR plan_annual_employee_limit >= 0::numeric) AND (employer_match_period_cap IS NULL OR employer_match_period_cap >= 0::numeric) AND (employer_match_annual_cap IS NULL OR employer_match_annual_cap >= 0::numeric)", name: "retirement_elections_amount_ranges"
    t.check_constraint "traditional_rate >= 0::numeric AND traditional_rate <= 1::numeric AND roth_rate >= 0::numeric AND roth_rate <= 1::numeric AND employer_match_rate >= 0::numeric AND employer_match_rate <= 1::numeric AND (employer_match_deferral_cap_rate IS NULL OR employer_match_deferral_cap_rate >= 0::numeric AND employer_match_deferral_cap_rate <= 1::numeric)", name: "retirement_elections_rate_ranges"
    t.check_constraint "true_up_policy::text <> 'year_to_date'::text OR employer_match_mode::text <> 'compensation_percentage'::text OR eligible_compensation::text = 'gross_wages'::text", name: "retirement_elections_true_up_compensation"
  end

  create_table "employee_status_events", force: :cascade do |t|
    t.bigint "actor_id"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.date "effective_date", null: false
    t.bigint "employee_id", null: false
    t.string "event_type", null: false
    t.text "internal_notes"
    t.date "last_worked_on"
    t.string "previous_status", null: false
    t.string "reason_category"
    t.string "resulting_status", null: false
    t.string "source", default: "operator", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_employee_status_events_on_actor_id"
    t.index ["company_id"], name: "index_employee_status_events_on_company_id"
    t.index ["employee_id", "effective_date", "id"], name: "idx_employee_status_events_timeline"
    t.index ["employee_id"], name: "index_employee_status_events_on_employee_id"
    t.check_constraint "event_type::text = ANY (ARRAY['terminated'::character varying::text, 'reactivated'::character varying::text])", name: "employee_status_events_type_check"
    t.check_constraint "last_worked_on IS NULL OR last_worked_on <= effective_date", name: "employee_status_events_last_worked_check"
    t.check_constraint "previous_status::text = ANY (ARRAY['active'::character varying::text, 'inactive'::character varying::text, 'terminated'::character varying::text])", name: "employee_status_events_previous_status_check"
    t.check_constraint "resulting_status::text = ANY (ARRAY['active'::character varying::text, 'inactive'::character varying::text, 'terminated'::character varying::text])", name: "employee_status_events_resulting_status_check"
    t.check_constraint "source::text = ANY (ARRAY['operator'::character varying::text, 'production_migration'::character varying::text])", name: "employee_status_events_source_check"
  end

  create_table "employee_tipped_occupations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "effective_from", null: false
    t.date "effective_to"
    t.bigint "employee_id", null: false
    t.text "notes"
    t.string "occupation_code", limit: 3, null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.index ["employee_id", "occupation_code", "effective_from"], name: "idx_employee_tipped_occupations_unique_start", unique: true
    t.index ["employee_id"], name: "index_employee_tipped_occupations_on_employee_id"
    t.check_constraint "effective_to IS NULL OR effective_to >= effective_from", name: "employee_tipped_occupation_date_order"
    t.check_constraint "occupation_code::text ~ '^[0-9]{3}$'::text", name: "employee_tipped_occupation_code_format"
  end

  create_table "employee_w4_elections", force: :cascade do |t|
    t.decimal "additional_withholding", precision: 10, scale: 2, default: "0.0", null: false
    t.integer "allowances", default: 0, null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.date "effective_on", null: false
    t.bigint "employee_id", null: false
    t.string "filing_status", null: false
    t.text "reason", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.decimal "w4_dependent_credit", precision: 10, scale: 2, default: "0.0", null: false
    t.integer "w4_form_version", default: 2020, null: false
    t.date "w4_signed_on"
    t.string "w4_source_reference"
    t.boolean "w4_step2_multiple_jobs", default: false, null: false
    t.decimal "w4_step4a_other_income", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "w4_step4b_deductions", precision: 10, scale: 2, default: "0.0", null: false
    t.index ["company_id", "effective_on"], name: "idx_employee_w4_elections_company_effective"
    t.index ["company_id"], name: "index_employee_w4_elections_on_company_id"
    t.index ["created_by_id"], name: "index_employee_w4_elections_on_created_by_id"
    t.index ["employee_id", "effective_on", "created_at"], name: "idx_employee_w4_elections_effective"
    t.index ["employee_id"], name: "index_employee_w4_elections_on_employee_id"
    t.check_constraint "filing_status::text = ANY (ARRAY['single'::character varying::text, 'married'::character varying::text, 'married_separate'::character varying::text, 'head_of_household'::character varying::text])", name: "employee_w4_elections_filing_status_check"
    t.check_constraint "source::text = ANY (ARRAY['staff'::character varying::text, 'client_approved'::character varying::text, 'employee_creation'::character varying::text, 'legacy_profile'::character varying::text, 'quickbooks_history'::character varying::text])", name: "employee_w4_elections_source_check"
  end

  create_table "employee_wage_rates", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.boolean "is_primary", default: false, null: false
    t.string "label", null: false
    t.decimal "rate", precision: 12, scale: 6
    t.datetime "updated_at", null: false
    t.index ["employee_id", "label"], name: "index_employee_wage_rates_on_employee_id_and_label", unique: true
    t.index ["employee_id"], name: "index_employee_wage_rates_on_employee_id"
  end

  create_table "employee_work_profiles", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "confirmation_status", default: "needs_confirmation", null: false
    t.datetime "confirmed_at"
    t.bigint "confirmed_by_id"
    t.datetime "created_at", null: false
    t.jsonb "daily_schedule", default: {}, null: false
    t.date "effective_on", null: false
    t.bigint "employee_id", null: false
    t.date "ends_on"
    t.string "exemption_category"
    t.text "exemption_reason"
    t.text "notes"
    t.string "overtime_status", default: "needs_review", null: false
    t.string "pay_basis", null: false
    t.text "salary_coverage_reason"
    t.decimal "salary_covers_weekly_hours", precision: 6, scale: 2
    t.string "source", default: "operator_confirmed", null: false
    t.decimal "standard_weekly_hours", precision: 6, scale: 2
    t.string "timekeeping_mode", default: "manual", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_employee_work_profiles_on_company_id"
    t.index ["confirmed_by_id"], name: "index_employee_work_profiles_on_confirmed_by_id"
    t.index ["employee_id", "effective_on"], name: "idx_employee_work_profiles_effective", unique: true
    t.index ["employee_id"], name: "idx_employee_work_profiles_one_current", unique: true, where: "(ends_on IS NULL)"
    t.index ["employee_id"], name: "index_employee_work_profiles_on_employee_id"
    t.check_constraint "confirmation_status::text = ANY (ARRAY['confirmed'::character varying::text, 'needs_confirmation'::character varying::text])", name: "employee_work_profiles_confirmation_check"
    t.check_constraint "ends_on IS NULL OR ends_on >= effective_on", name: "employee_work_profiles_dates_check"
    t.check_constraint "overtime_status::text = ANY (ARRAY['exempt'::character varying::text, 'nonexempt'::character varying::text, 'needs_review'::character varying::text])", name: "employee_work_profiles_overtime_status_check"
    t.check_constraint "pay_basis::text = ANY (ARRAY['hourly'::character varying::text, 'salary'::character varying::text, 'contractor'::character varying::text])", name: "employee_work_profiles_pay_basis_check"
    t.check_constraint "salary_covers_weekly_hours IS NULL OR salary_covers_weekly_hours >= 40::numeric AND salary_covers_weekly_hours <= 168::numeric", name: "employee_work_profiles_salary_coverage_check"
    t.check_constraint "source::text = ANY (ARRAY['operator_confirmed'::character varying::text, 'production_migration'::character varying::text, 'imported'::character varying::text, 'legacy_system_default'::character varying::text])", name: "employee_work_profiles_source_check"
    t.check_constraint "standard_weekly_hours IS NULL OR standard_weekly_hours > 0::numeric AND standard_weekly_hours <= 168::numeric", name: "employee_work_profiles_weekly_hours_check"
    t.check_constraint "timekeeping_mode::text = ANY (ARRAY['imported'::character varying::text, 'manual'::character varying::text, 'schedule_with_exceptions'::character varying::text])", name: "employee_work_profiles_mode_check"
  end

  add_check_constraint "employee_work_profiles", "pay_basis::text <> 'salary'::text OR overtime_status::text <> 'nonexempt'::text OR salary_covers_weekly_hours IS NOT NULL AND salary_coverage_reason IS NOT NULL", name: "employee_work_profiles_nonexempt_basis_check", validate: false

  create_table "employee_ytd_totals", force: :cascade do |t|
    t.decimal "bonus", precision: 14, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.decimal "gross_pay", precision: 14, scale: 2, default: "0.0"
    t.decimal "insurance", precision: 14, scale: 2, default: "0.0"
    t.decimal "loans", precision: 14, scale: 2, default: "0.0"
    t.decimal "medicare_tax", precision: 14, scale: 2, default: "0.0"
    t.decimal "net_pay", precision: 14, scale: 2, default: "0.0"
    t.decimal "overtime_pay", precision: 14, scale: 2, default: "0.0"
    t.decimal "retirement", precision: 14, scale: 2, default: "0.0"
    t.decimal "roth_retirement", precision: 14, scale: 2, default: "0.0"
    t.decimal "social_security_tax", precision: 14, scale: 2, default: "0.0"
    t.decimal "tips", precision: 14, scale: 2, default: "0.0"
    t.decimal "tips_paid_out", precision: 14, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.decimal "withholding_tax", precision: 14, scale: 2, default: "0.0"
    t.integer "year", null: false
    t.index ["employee_id", "year"], name: "index_employee_ytd_totals_on_employee_id_and_year", unique: true
    t.index ["employee_id"], name: "index_employee_ytd_totals_on_employee_id"
  end

  create_table "employees", force: :cascade do |t|
    t.decimal "additional_withholding", precision: 10, scale: 2, default: "0.0"
    t.string "address_line1"
    t.string "address_line2"
    t.integer "allowances", default: 0
    t.string "bank_account_number_encrypted"
    t.string "bank_routing_number_encrypted"
    t.string "business_name"
    t.string "city"
    t.bigint "company_id", null: false
    t.jsonb "configuration_review_items", default: [], null: false
    t.string "configuration_review_status", default: "complete", null: false
    t.string "configuration_source"
    t.string "contractor_ein"
    t.string "contractor_pay_type", default: "flat_fee"
    t.string "contractor_type", default: "individual"
    t.datetime "created_at", null: false
    t.date "date_of_birth"
    t.jsonb "default_custom_earnings", default: [], null: false
    t.jsonb "default_payroll_adjustments", default: [], null: false
    t.bigint "department_id"
    t.boolean "document_readiness_required", default: false, null: false
    t.string "email"
    t.decimal "employer_retirement_match_rate", precision: 5, scale: 4, default: "0.0"
    t.decimal "employer_roth_match_rate", precision: 5, scale: 4, default: "0.0"
    t.string "employment_type", default: "hourly", null: false
    t.string "filing_status", default: "single"
    t.string "first_name", null: false
    t.date "hire_date"
    t.string "job_title"
    t.string "last_name", null: false
    t.string "middle_name"
    t.string "pay_frequency", default: "biweekly"
    t.decimal "pay_rate", precision: 18, scale: 6, null: false
    t.string "phone"
    t.boolean "portal_pending_approval", default: false, null: false
    t.bigint "previous_employee_id"
    t.decimal "retirement_rate", precision: 5, scale: 4, default: "0.0"
    t.decimal "roth_retirement_rate", precision: 5, scale: 4, default: "0.0"
    t.string "salary_type", default: "annual", null: false
    t.string "ssn_encrypted"
    t.string "state"
    t.string "status", default: "active"
    t.date "termination_date"
    t.datetime "updated_at", null: false
    t.decimal "w4_dependent_credit", precision: 10, scale: 2, default: "0.0", null: false
    t.date "w4_effective_on"
    t.integer "w4_form_version", default: 2020, null: false
    t.date "w4_signed_on"
    t.string "w4_source_reference"
    t.boolean "w4_step2_multiple_jobs", default: false, null: false
    t.decimal "w4_step4a_other_income", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "w4_step4b_deductions", precision: 10, scale: 2, default: "0.0", null: false
    t.boolean "w9_on_file", default: false, null: false
    t.string "zip"
    t.index ["company_id", "last_name", "first_name"], name: "index_employees_on_company_id_and_last_name_and_first_name"
    t.index ["company_id"], name: "index_employees_on_company_id"
    t.index ["department_id"], name: "index_employees_on_department_id"
    t.index ["employment_type"], name: "index_employees_on_employment_type"
    t.index ["id", "company_id"], name: "idx_employees_document_readiness_tenant_key", unique: true
    t.index ["previous_employee_id"], name: "index_employees_on_previous_employee_id", unique: true
    t.index ["status"], name: "index_employees_on_status"
    t.check_constraint "configuration_review_status::text = ANY (ARRAY['complete'::character varying::text, 'needs_review'::character varying::text])", name: "employees_configuration_review_status_check"
    t.check_constraint "configuration_source IS NULL OR configuration_source::text = 'quickbooks_history'::text", name: "employees_configuration_source_check"
    t.check_constraint "jsonb_typeof(configuration_review_items) = 'array'::text", name: "employees_configuration_review_items_array"
    t.check_constraint "portal_pending_approval = false OR status::text = 'inactive'::text", name: "employees_portal_pending_inactive_check"
  end

  create_table "filing_status_configs", force: :cascade do |t|
    t.bigint "annual_tax_config_id", null: false
    t.datetime "created_at", null: false
    t.string "filing_status", null: false
    t.decimal "standard_deduction", precision: 12, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["annual_tax_config_id", "filing_status"], name: "idx_filing_status_configs_unique", unique: true
    t.index ["annual_tax_config_id"], name: "index_filing_status_configs_on_annual_tax_config_id"
  end

  create_table "form500_filings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "confirmation_number"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.jsonb "fields", default: {}, null: false
    t.text "notes"
    t.bigint "pay_period_id", null: false
    t.decimal "payment_amount", precision: 12, scale: 2
    t.date "payment_date"
    t.boolean "receipt_attached", default: false, null: false
    t.string "status", default: "prepared", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["company_id", "status"], name: "index_form500_filings_on_company_id_and_status"
    t.index ["company_id"], name: "index_form500_filings_on_company_id"
    t.index ["created_by_id"], name: "index_form500_filings_on_created_by_id"
    t.index ["pay_period_id"], name: "index_form500_filings_on_pay_period_id", unique: true
    t.index ["updated_by_id"], name: "index_form500_filings_on_updated_by_id"
  end

  create_table "general_transmittal_artifacts", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.bigint "company_id", null: false
    t.string "content_type", default: "application/pdf", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "filename", null: false
    t.bigint "general_transmittal_id", null: false
    t.string "sha256", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.string "storage_key", null: false
    t.string "template_version", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["company_id"], name: "index_general_transmittal_artifacts_on_company_id"
    t.index ["created_by_id"], name: "index_general_transmittal_artifacts_on_created_by_id"
    t.index ["general_transmittal_id", "version_number"], name: "idx_transmittal_artifacts_on_transmittal_version", unique: true
    t.index ["storage_key"], name: "index_general_transmittal_artifacts_on_storage_key", unique: true
    t.check_constraint "byte_size > 0", name: "general_transmittal_artifacts_byte_size_positive"
    t.check_constraint "char_length(sha256::text) = 64", name: "general_transmittal_artifacts_sha256_length"
    t.check_constraint "version_number > 0", name: "general_transmittal_artifacts_version_positive"
  end

  create_table "general_transmittal_items", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2
    t.string "check_number"
    t.datetime "created_at", null: false
    t.jsonb "details", default: [], null: false
    t.bigint "general_transmittal_id", null: false
    t.boolean "included", default: true, null: false
    t.string "item_type", default: "manual", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "payable_to"
    t.integer "position", default: 0, null: false
    t.bigint "source_id"
    t.string "source_key"
    t.string "source_type"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["general_transmittal_id", "position"], name: "idx_general_transmittal_items_on_transmittal_position"
    t.index ["general_transmittal_id", "source_key"], name: "idx_transmittal_items_on_transmittal_source_key", unique: true, where: "(source_key IS NOT NULL)"
    t.index ["general_transmittal_id"], name: "idx_general_transmittal_items_on_transmittal"
    t.index ["source_type", "source_id"], name: "idx_general_transmittal_items_on_source"
    t.check_constraint "amount IS NULL OR amount >= 0::numeric", name: "general_transmittal_items_amount_nonnegative"
  end

  create_table "general_transmittals", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "generated_at"
    t.jsonb "notes", default: [], null: false
    t.bigint "pay_period_id"
    t.string "preparer_name"
    t.string "recipient_name"
    t.string "source_kind", default: "standalone", null: false
    t.string "status", default: "draft", null: false
    t.string "title", null: false
    t.date "transmittal_date", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["company_id", "transmittal_date"], name: "idx_general_transmittals_on_company_date"
    t.index ["company_id"], name: "index_general_transmittals_on_company_id"
    t.index ["created_by_id"], name: "index_general_transmittals_on_created_by_id"
    t.index ["pay_period_id"], name: "index_general_transmittals_on_pay_period_id", unique: true, where: "(pay_period_id IS NOT NULL)"
    t.index ["updated_by_id"], name: "index_general_transmittals_on_updated_by_id"
    t.check_constraint "source_kind::text = ANY (ARRAY['standalone'::character varying::text, 'pay_period'::character varying::text])", name: "general_transmittals_source_kind_check"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'generated'::character varying::text])", name: "general_transmittals_status_check"
  end

  create_table "historical_client_bootstrap_dispatches", force: :cascade do |t|
    t.string "attempt_token", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "dispatch_attempts", default: 0, null: false
    t.datetime "enqueued_at"
    t.bigint "historical_client_bootstrap_id", null: false
    t.text "last_error"
    t.bigint "requested_by_id"
    t.datetime "updated_at", null: false
    t.index ["completed_at", "enqueued_at"], name: "idx_historical_bootstrap_dispatch_due"
    t.index ["historical_client_bootstrap_id", "attempt_token"], name: "idx_historical_bootstrap_dispatch_attempt", unique: true
    t.index ["requested_by_id"], name: "index_historical_client_bootstrap_dispatches_on_requested_by_id"
  end

  create_table "historical_client_bootstraps", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_id"
    t.text "apply_error"
    t.datetime "apply_started_at"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.bigint "historical_import_batch_id", null: false
    t.string "plan_digest", null: false
    t.jsonb "preview_summary", default: {}, null: false
    t.jsonb "review_items", default: [], null: false
    t.string "status", default: "previewed", null: false
    t.datetime "updated_at", null: false
    t.jsonb "validation_errors", default: [], null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["applied_by_id"], name: "index_historical_client_bootstraps_on_applied_by_id"
    t.index ["company_id", "status"], name: "index_historical_client_bootstraps_on_company_id_and_status"
    t.index ["created_by_id"], name: "index_historical_client_bootstraps_on_created_by_id"
    t.index ["historical_import_batch_id"], name: "idx_on_historical_import_batch_id_e2c1f62422", unique: true
    t.check_constraint "jsonb_typeof(preview_summary) = 'object'::text", name: "historical_client_bootstraps_summary_object"
    t.check_constraint "jsonb_typeof(warnings) = 'array'::text AND jsonb_typeof(validation_errors) = 'array'::text AND jsonb_typeof(review_items) = 'array'::text", name: "historical_client_bootstraps_arrays"
    t.check_constraint "status::text = ANY (ARRAY['previewed'::character varying::text, 'pending'::character varying::text, 'applied'::character varying::text, 'failed'::character varying::text])", name: "historical_client_bootstraps_status_check"
  end

  create_table "historical_employee_ytd_balances", force: :cascade do |t|
    t.decimal "additional_withholding", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "after_tax_deductions", precision: 15, scale: 2, default: "0.0", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.decimal "employee_taxes", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "employer_contributions", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "employer_medicare_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "employer_social_security_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "employer_taxes", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "federal_income_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "fit_taxable_wages", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "gross_pay", precision: 15, scale: 2, default: "0.0", null: false
    t.bigint "historical_ytd_bridge_id", null: false
    t.decimal "insurance", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "loans", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "medicare_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "medicare_taxable_wages", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "net_pay", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "non_taxable_pay", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "pretax_deductions", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "reported_tips", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "retirement", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "roth_retirement", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "social_security_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "social_security_taxable_tips", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "social_security_taxable_wages", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "source_breakdown", default: {}, null: false
    t.integer "tax_year", null: false
    t.date "through_pay_date", null: false
    t.date "through_period_end", null: false
    t.decimal "tips_paid_out", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "employee_id", "tax_year"], name: "idx_on_company_id_employee_id_tax_year_ee7e837958"
    t.index ["employee_id", "tax_year"], name: "idx_historical_ytd_balances_employee_year"
    t.index ["historical_ytd_bridge_id", "employee_id", "tax_year"], name: "idx_historical_ytd_balances_unique_employee_year", unique: true
    t.check_constraint "jsonb_typeof(source_breakdown) = 'object'::text", name: "historical_ytd_balances_source_object"
    t.check_constraint "tax_year >= 2000 AND tax_year <= 2200", name: "historical_ytd_balances_tax_year_check"
    t.check_constraint "through_pay_date >= through_period_end", name: "historical_ytd_balances_boundary_order"
  end

  create_table "historical_import_batches", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_id"
    t.text "apply_acknowledgement"
    t.string "bundle_digest", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "importer_version", null: false
    t.datetime "locked_at"
    t.bigint "locked_by_id"
    t.jsonb "preview_summary", default: {}, null: false
    t.jsonb "reconciliation_summary", default: {}, null: false
    t.jsonb "source_file_manifest", default: [], null: false
    t.string "source_label", null: false
    t.string "source_system", default: "quickbooks_online", null: false
    t.string "status", default: "previewed", null: false
    t.jsonb "tax_wage_reconciliation", default: {}, null: false
    t.datetime "updated_at", null: false
    t.jsonb "validation_errors", default: [], null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["applied_by_id"], name: "index_historical_import_batches_on_applied_by_id"
    t.index ["company_id", "source_system", "bundle_digest", "importer_version"], name: "idx_historical_batches_unique_bundle_version", unique: true
    t.index ["company_id"], name: "index_historical_import_batches_on_company_id"
    t.index ["created_by_id"], name: "index_historical_import_batches_on_created_by_id"
    t.index ["id", "company_id"], name: "idx_historical_import_batches_tenant_key", unique: true
    t.index ["locked_by_id"], name: "index_historical_import_batches_on_locked_by_id"
    t.check_constraint "jsonb_typeof(tax_wage_reconciliation) = 'object'::text", name: "historical_import_batches_tax_wage_object"
    t.check_constraint "source_system::text = 'quickbooks_online'::text", name: "historical_import_batches_source"
    t.check_constraint "status::text = ANY (ARRAY['previewed'::character varying::text, 'applied'::character varying::text, 'locked'::character varying::text, 'failed'::character varying::text])", name: "historical_import_batches_status"
  end

  create_table "historical_import_cutover_reviews", force: :cascade do |t|
    t.text "approval_acknowledgement"
    t.text "approval_notes"
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.jsonb "attestations", default: {}, null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "evidence", default: {}, null: false
    t.string "evidence_digest"
    t.jsonb "exception_dispositions", default: {}, null: false
    t.bigint "historical_import_batch_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.text "verification_error"
    t.datetime "verification_started_at"
    t.datetime "verified_at"
    t.bigint "verified_by_id"
    t.index ["approved_by_id"], name: "index_historical_import_cutover_reviews_on_approved_by_id"
    t.index ["company_id"], name: "index_historical_import_cutover_reviews_on_company_id"
    t.index ["historical_import_batch_id"], name: "idx_historical_cutover_reviews_batch", unique: true
    t.index ["verified_by_id"], name: "index_historical_import_cutover_reviews_on_verified_by_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'approved'::character varying::text, 'failed'::character varying::text])", name: "historical_cutover_reviews_status"
  end

  create_table "historical_import_source_files", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.bigint "company_id", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.bigint "historical_import_batch_id", null: false
    t.string "original_filename", null: false
    t.integer "position", null: false
    t.string "report_type", null: false
    t.string "sha256", null: false
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.bigint "uploaded_by_id"
    t.string "verification_error"
    t.string "verification_status", default: "verified", null: false
    t.datetime "verified_at"
    t.index ["company_id"], name: "index_historical_import_source_files_on_company_id"
    t.index ["historical_import_batch_id", "position"], name: "idx_historical_source_files_batch_position", unique: true
    t.index ["historical_import_batch_id"], name: "idx_on_historical_import_batch_id_77cd828a3a"
    t.index ["storage_key"], name: "index_historical_import_source_files_on_storage_key", unique: true
    t.index ["uploaded_by_id"], name: "index_historical_import_source_files_on_uploaded_by_id"
    t.check_constraint "byte_size > 0", name: "historical_source_files_positive_size"
    t.check_constraint "verification_status::text = ANY (ARRAY['verified'::character varying::text, 'failed'::character varying::text])", name: "historical_source_files_verification_status"
  end

  create_table "historical_pay_periods", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.date "end_date", null: false
    t.string "external_key", null: false
    t.bigint "historical_import_batch_id", null: false
    t.date "pay_date", null: false
    t.integer "paycheck_count", default: 0, null: false
    t.string "period_type", default: "regular", null: false
    t.string "source_label", null: false
    t.date "start_date", null: false
    t.jsonb "totals", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "pay_date"], name: "index_historical_pay_periods_on_company_id_and_pay_date"
    t.index ["company_id"], name: "index_historical_pay_periods_on_company_id"
    t.index ["historical_import_batch_id", "external_key"], name: "idx_historical_periods_unique_source", unique: true
    t.index ["historical_import_batch_id"], name: "index_historical_pay_periods_on_historical_import_batch_id"
    t.check_constraint "end_date >= start_date AND pay_date >= end_date", name: "historical_pay_periods_date_order"
    t.check_constraint "period_type::text = ANY (ARRAY['regular'::character varying::text, 'opening_summary'::character varying::text])", name: "historical_pay_periods_type"
  end

  create_table "historical_paycheck_adjustment_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.string "event_type", null: false
    t.bigint "historical_paycheck_adjustment_id", null: false
    t.bigint "historical_ytd_bridge_id"
    t.jsonb "metadata", default: {}, null: false
    t.text "note"
    t.index ["company_id", "created_at"], name: "idx_historical_adjustment_events_company_time"
    t.index ["created_by_id"], name: "idx_historical_adjustment_events_creator"
    t.index ["historical_paycheck_adjustment_id"], name: "idx_historical_adjustment_events_adjustment"
    t.index ["historical_ytd_bridge_id"], name: "idx_historical_adjustment_events_bridge"
    t.check_constraint "event_type::text = ANY (ARRAY['filing_reviewed_no_amendment'::character varying::text, 'filing_amendment_required'::character varying::text, 'filing_amendment_filed_external'::character varying::text, 'filing_review_reopened'::character varying::text, 'downstream_impact_acknowledged'::character varying::text, 'ytd_revision_activated'::character varying::text])", name: "historical_adjustment_events_type_check"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "historical_adjustment_events_metadata_object"
  end

  create_table "historical_paycheck_adjustments", force: :cascade do |t|
    t.decimal "adjusted_gross", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "after_tax_deduction_breakdown", default: [], null: false
    t.decimal "after_tax_deductions", precision: 15, scale: 2, default: "0.0", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.jsonb "earnings_breakdown", default: [], null: false
    t.date "effective_pay_date", null: false
    t.jsonb "employee_tax_breakdown", default: [], null: false
    t.decimal "employee_taxes", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "employer_contribution_breakdown", default: [], null: false
    t.decimal "employer_contributions", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "employer_tax_breakdown", default: [], null: false
    t.decimal "employer_taxes", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "evidence_metadata", default: {}, null: false
    t.string "external_reference"
    t.decimal "federal_income_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.integer "filing_quarter", null: false
    t.integer "filing_year", null: false
    t.decimal "gross_pay", precision: 15, scale: 2, default: "0.0", null: false
    t.bigint "historical_paycheck_id", null: false
    t.jsonb "hours_breakdown", default: [], null: false
    t.decimal "hours_total", precision: 12, scale: 4, default: "0.0", null: false
    t.string "idempotency_key", null: false
    t.string "kind", null: false
    t.decimal "medicare_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "net_pay", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "pretax_deduction_breakdown", default: [], null: false
    t.decimal "pretax_deductions", precision: 15, scale: 2, default: "0.0", null: false
    t.text "reason", null: false
    t.bigint "reverses_adjustment_id"
    t.decimal "social_security_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "total_payroll_cost", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "effective_pay_date"], name: "idx_historical_adjustments_company_date"
    t.index ["company_id", "idempotency_key"], name: "idx_historical_adjustments_idempotency", unique: true
    t.index ["created_by_id"], name: "idx_historical_adjustments_creator"
    t.index ["historical_paycheck_id"], name: "idx_historical_adjustments_paycheck"
    t.index ["id", "company_id"], name: "idx_historical_adjustments_tenant_key", unique: true
    t.index ["reverses_adjustment_id"], name: "idx_historical_adjustments_one_reversal", unique: true, where: "(reverses_adjustment_id IS NOT NULL)"
    t.check_constraint "filing_year >= 2000 AND filing_year <= 2200 AND filing_quarter >= 1 AND filing_quarter <= 4", name: "historical_adjustments_filing_period_check"
    t.check_constraint "jsonb_typeof(after_tax_deduction_breakdown) = 'array'::text", name: "historical_adjustments_after_tax_deduction_array"
    t.check_constraint "jsonb_typeof(earnings_breakdown) = 'array'::text", name: "historical_adjustments_earnings_array"
    t.check_constraint "jsonb_typeof(employee_tax_breakdown) = 'array'::text", name: "historical_adjustments_employee_tax_array"
    t.check_constraint "jsonb_typeof(employer_contribution_breakdown) = 'array'::text", name: "historical_adjustments_employer_contribution_array"
    t.check_constraint "jsonb_typeof(employer_tax_breakdown) = 'array'::text", name: "historical_adjustments_employer_tax_array"
    t.check_constraint "jsonb_typeof(evidence_metadata) = 'object'::text", name: "historical_adjustments_evidence_object"
    t.check_constraint "jsonb_typeof(hours_breakdown) = 'array'::text", name: "historical_adjustments_hours_array"
    t.check_constraint "jsonb_typeof(pretax_deduction_breakdown) = 'array'::text", name: "historical_adjustments_pretax_deduction_array"
    t.check_constraint "kind::text = ANY (ARRAY['correction'::character varying::text, 'void'::character varying::text, 'reversal'::character varying::text])", name: "historical_adjustments_kind_check"
  end

  create_table "historical_paychecks", force: :cascade do |t|
    t.decimal "adjusted_gross", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "after_tax_deduction_breakdown", default: [], null: false
    t.decimal "after_tax_deductions", precision: 15, scale: 2, default: "0.0", null: false
    t.string "check_number"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "earnings_breakdown", default: [], null: false
    t.bigint "employee_id"
    t.jsonb "employee_tax_breakdown", default: [], null: false
    t.decimal "employee_taxes", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "employer_contribution_breakdown", default: [], null: false
    t.decimal "employer_contributions", precision: 15, scale: 2, default: "0.0", null: false
    t.jsonb "employer_tax_breakdown", default: [], null: false
    t.decimal "employer_taxes", precision: 15, scale: 2, default: "0.0", null: false
    t.string "external_key", null: false
    t.decimal "federal_income_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "gross_pay", precision: 15, scale: 2, default: "0.0", null: false
    t.bigint "historical_import_batch_id", null: false
    t.bigint "historical_pay_period_id", null: false
    t.bigint "historical_worker_id", null: false
    t.jsonb "hours_breakdown", default: [], null: false
    t.decimal "hours_total", precision: 12, scale: 4, default: "0.0", null: false
    t.decimal "medicare_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "net_pay", precision: 15, scale: 2, default: "0.0", null: false
    t.date "pay_date", null: false
    t.string "payment_method"
    t.date "period_end", null: false
    t.date "period_start", null: false
    t.jsonb "pretax_deduction_breakdown", default: [], null: false
    t.decimal "pretax_deductions", precision: 15, scale: 2, default: "0.0", null: false
    t.string "reconciliation_status", null: false
    t.decimal "social_security_tax", precision: 15, scale: 2, default: "0.0", null: false
    t.string "source_employee_name", null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.integer "source_row_number", null: false
    t.string "source_status", default: "recorded", null: false
    t.decimal "total_payroll_cost", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "external_key"], name: "index_historical_paychecks_on_company_id_and_external_key"
    t.index ["company_id", "pay_date"], name: "index_historical_paychecks_on_company_id_and_pay_date"
    t.index ["company_id"], name: "index_historical_paychecks_on_company_id"
    t.index ["employee_id"], name: "index_historical_paychecks_on_employee_id"
    t.index ["historical_import_batch_id", "external_key"], name: "idx_historical_paychecks_unique_source", unique: true
    t.index ["historical_import_batch_id"], name: "index_historical_paychecks_on_historical_import_batch_id"
    t.index ["historical_pay_period_id"], name: "index_historical_paychecks_on_historical_pay_period_id"
    t.index ["historical_worker_id", "pay_date"], name: "idx_on_historical_worker_id_pay_date_085f957883"
    t.index ["historical_worker_id"], name: "index_historical_paychecks_on_historical_worker_id"
    t.index ["id", "company_id"], name: "idx_historical_paychecks_tenant_key", unique: true
    t.check_constraint "period_end >= period_start AND pay_date >= period_end", name: "historical_paychecks_date_order"
    t.check_constraint "reconciliation_status::text = ANY (ARRAY['matched'::character varying::text, 'opening_summary'::character varying::text, 'unmatched'::character varying::text])", name: "historical_paychecks_reconciliation_status"
  end

  create_table "historical_tax_wage_reports", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "historical_import_batch_id", null: false
    t.bigint "historical_import_source_file_id", null: false
    t.date "period_end", null: false
    t.date "period_start", null: false
    t.string "report_digest", null: false
    t.string "scope", null: false
    t.integer "source_position", null: false
    t.jsonb "tax_lines", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "period_end"], name: "index_historical_tax_wage_reports_on_company_id_and_period_end"
    t.index ["historical_import_batch_id", "period_start", "period_end"], name: "idx_historical_tax_reports_unique_period", unique: true
    t.index ["historical_import_source_file_id"], name: "idx_historical_tax_reports_unique_source", unique: true
    t.check_constraint "jsonb_typeof(tax_lines) = 'object'::text", name: "historical_tax_wage_reports_lines_object"
    t.check_constraint "period_end >= period_start", name: "historical_tax_wage_reports_date_order"
    t.check_constraint "scope::text = ANY (ARRAY['quarterly'::character varying::text, 'quarterly_year_to_date'::character varying::text, 'annual'::character varying::text, 'year_to_date'::character varying::text, 'multi_year'::character varying::text])", name: "historical_tax_wage_reports_scope_check"
  end

  create_table "historical_workers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id"
    t.string "external_key", null: false
    t.date "hire_date"
    t.bigint "historical_import_batch_id", null: false
    t.string "mapping_status", default: "needs_review", null: false
    t.decimal "match_confidence", precision: 5, scale: 4
    t.string "match_method"
    t.string "normalized_name", null: false
    t.text "private_snapshot"
    t.string "source_name", null: false
    t.string "source_status", default: "unknown", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "normalized_name"], name: "index_historical_workers_on_company_id_and_normalized_name"
    t.index ["company_id"], name: "index_historical_workers_on_company_id"
    t.index ["employee_id"], name: "index_historical_workers_on_employee_id"
    t.index ["historical_import_batch_id", "external_key"], name: "idx_historical_workers_unique_source", unique: true
    t.index ["historical_import_batch_id"], name: "index_historical_workers_on_historical_import_batch_id"
    t.check_constraint "mapping_status::text = ANY (ARRAY['needs_review'::character varying::text, 'exact_match'::character varying::text, 'manual_match'::character varying::text, 'archive_only'::character varying::text])", name: "historical_workers_mapping_status"
    t.check_constraint "source_status::text = ANY (ARRAY['active'::character varying::text, 'inactive'::character varying::text, 'unknown'::character varying::text])", name: "historical_workers_source_status"
  end

  create_table "historical_ytd_bridges", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_id"
    t.text "apply_acknowledgement"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.bigint "historical_client_bootstrap_id", null: false
    t.bigint "historical_import_batch_id", null: false
    t.string "plan_digest", null: false
    t.jsonb "preview_summary", default: {}, null: false
    t.jsonb "reconciliation_summary", default: {}, null: false
    t.integer "revision", default: 1, null: false
    t.string "status", default: "previewed", null: false
    t.bigint "supersedes_historical_ytd_bridge_id"
    t.datetime "updated_at", null: false
    t.jsonb "validation_errors", default: [], null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["applied_by_id"], name: "index_historical_ytd_bridges_on_applied_by_id"
    t.index ["company_id", "status"], name: "index_historical_ytd_bridges_on_company_id_and_status"
    t.index ["created_by_id"], name: "index_historical_ytd_bridges_on_created_by_id"
    t.index ["historical_client_bootstrap_id"], name: "idx_historical_ytd_bridges_bootstrap"
    t.index ["historical_import_batch_id", "revision"], name: "idx_historical_ytd_bridges_batch_revision", unique: true
    t.index ["id", "company_id"], name: "idx_historical_ytd_bridges_tenant_key", unique: true
    t.index ["supersedes_historical_ytd_bridge_id"], name: "idx_historical_ytd_bridges_one_successor", unique: true, where: "(supersedes_historical_ytd_bridge_id IS NOT NULL)"
    t.check_constraint "jsonb_typeof(preview_summary) = 'object'::text AND jsonb_typeof(reconciliation_summary) = 'object'::text", name: "historical_ytd_bridges_summary_objects"
    t.check_constraint "jsonb_typeof(warnings) = 'array'::text AND jsonb_typeof(validation_errors) = 'array'::text", name: "historical_ytd_bridges_arrays"
    t.check_constraint "preview_summary ? 'through_period_end'::text AND preview_summary ? 'through_pay_date'::text AND (preview_summary ->> 'through_period_end'::text) ~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'::text AND (preview_summary ->> 'through_pay_date'::text) ~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'::text AND (preview_summary ->> 'through_pay_date'::text) >= (preview_summary ->> 'through_period_end'::text)", name: "historical_ytd_bridges_boundary_order"
    t.check_constraint "revision > 0", name: "historical_ytd_bridges_revision_positive"
    t.check_constraint "status::text = 'applied'::text AND applied_at IS NOT NULL AND applied_by_id IS NOT NULL AND apply_acknowledgement IS NOT NULL OR status::text = 'previewed'::text AND applied_at IS NULL AND applied_by_id IS NULL AND apply_acknowledgement IS NULL", name: "historical_ytd_bridges_status_audit_fields"
    t.check_constraint "status::text = ANY (ARRAY['previewed'::character varying::text, 'applied'::character varying::text])", name: "historical_ytd_bridges_status_check"
  end

  create_table "information_return_thresholds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "effective_on", null: false
    t.string "form_type", null: false
    t.string "source_url", null: false
    t.integer "tax_year", null: false
    t.decimal "threshold_amount", precision: 14, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["form_type", "tax_year"], name: "idx_information_return_thresholds_form_year", unique: true
    t.check_constraint "threshold_amount >= 0::numeric", name: "information_return_threshold_nonnegative"
  end

  create_table "invoice_artifacts", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "filename", null: false
    t.bigint "invoice_id", null: false
    t.string "kind", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "renderer_version"
    t.string "sha256", null: false
    t.string "storage_key", null: false
    t.string "template_version"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_invoice_artifacts_on_created_by_id"
    t.index ["invoice_id", "kind", "created_at"], name: "idx_invoice_artifacts_on_invoice_kind_created"
    t.index ["invoice_id"], name: "index_invoice_artifacts_on_invoice_id"
    t.index ["organization_id"], name: "index_invoice_artifacts_on_organization_id"
    t.index ["storage_key"], name: "index_invoice_artifacts_on_storage_key", unique: true
    t.check_constraint "byte_size >= 0", name: "check_invoice_artifacts_byte_size"
    t.check_constraint "kind::text = ANY (ARRAY['issued_pdf'::character varying::text, 'imported_original'::character varying::text, 'legacy_snapshot'::character varying::text, 'credit_note'::character varying::text, 'payment_receipt'::character varying::text])", name: "check_invoice_artifacts_kind"
  end

  create_table "invoice_billing_profiles", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "address"
    t.datetime "created_at", null: false
    t.text "default_payment_terms"
    t.string "email"
    t.text "footer_note"
    t.string "invoice_prefix"
    t.boolean "is_default", default: false, null: false
    t.string "legal_name"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.text "payment_instructions"
    t.string "phone"
    t.string "remit_to"
    t.datetime "updated_at", null: false
    t.string "website"
    t.index ["organization_id", "is_default"], name: "index_invoice_billing_profiles_one_default_per_org", unique: true, where: "(is_default = true)"
    t.index ["organization_id", "name"], name: "index_invoice_billing_profiles_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_invoice_billing_profiles_on_organization_id"
  end

  create_table "invoice_chat_messages", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.boolean "has_preview", default: false, null: false
    t.jsonb "image_urls", default: [], null: false
    t.bigint "invoice_chat_session_id", null: false
    t.jsonb "preview", default: {}, null: false
    t.integer "preview_version"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_chat_session_id", "created_at"], name: "idx_invoice_chat_messages_on_session_created"
    t.index ["invoice_chat_session_id"], name: "index_invoice_chat_messages_on_invoice_chat_session_id"
    t.check_constraint "role::text = ANY (ARRAY['user'::character varying::text, 'assistant'::character varying::text])", name: "check_invoice_chat_messages_role"
  end

  create_table "invoice_chat_sessions", force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.bigint "company_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.jsonb "current_preview", default: {}, null: false
    t.integer "current_preview_version", default: 0, null: false
    t.bigint "invoice_id"
    t.bigint "invoice_recipient_id"
    t.bigint "organization_id", null: false
    t.string "status", default: "active", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["company_id", "archived", "updated_at"], name: "idx_invoice_chat_sessions_on_company_archive_updated"
    t.index ["company_id"], name: "index_invoice_chat_sessions_on_company_id"
    t.index ["created_by_id"], name: "index_invoice_chat_sessions_on_created_by_id"
    t.index ["invoice_id"], name: "index_invoice_chat_sessions_on_invoice_id"
    t.index ["invoice_recipient_id"], name: "index_invoice_chat_sessions_on_invoice_recipient_id"
    t.index ["organization_id", "archived", "updated_at"], name: "idx_invoice_chat_sessions_on_org_archive_updated"
    t.index ["organization_id"], name: "index_invoice_chat_sessions_on_organization_id"
    t.index ["updated_by_id"], name: "index_invoice_chat_sessions_on_updated_by_id"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'invoice_created'::character varying::text, 'archived'::character varying::text])", name: "check_invoice_chat_sessions_status"
  end

  create_table "invoice_credit_notes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "credit_number", null: false
    t.string "currency", default: "USD", null: false
    t.bigint "invoice_id", null: false
    t.date "issue_date", null: false
    t.bigint "issued_by_id"
    t.bigint "organization_id", null: false
    t.text "reason", null: false
    t.string "status", default: "issued", null: false
    t.decimal "total_amount", precision: 14, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.index ["invoice_id", "issue_date"], name: "idx_invoice_credit_notes_invoice_date"
    t.index ["invoice_id"], name: "index_invoice_credit_notes_on_invoice_id"
    t.index ["issued_by_id"], name: "index_invoice_credit_notes_on_issued_by_id"
    t.index ["organization_id", "credit_number"], name: "idx_invoice_credit_notes_unique_number", unique: true
    t.index ["organization_id"], name: "index_invoice_credit_notes_on_organization_id"
    t.index ["voided_by_id"], name: "index_invoice_credit_notes_on_voided_by_id"
    t.check_constraint "status::text = ANY (ARRAY['issued'::character varying::text, 'voided'::character varying::text])", name: "check_invoice_credit_notes_status"
    t.check_constraint "total_amount > 0::numeric", name: "check_invoice_credit_notes_positive_amount"
  end

  create_table "invoice_deliveries", force: :cascade do |t|
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at", null: false
    t.bigint "invoice_artifact_id"
    t.bigint "invoice_id", null: false
    t.text "notes"
    t.bigint "organization_id", null: false
    t.string "provider_reference"
    t.string "recipient"
    t.bigint "recorded_by_id"
    t.datetime "updated_at", null: false
    t.index ["invoice_artifact_id"], name: "index_invoice_deliveries_on_invoice_artifact_id"
    t.index ["invoice_id", "delivered_at"], name: "idx_invoice_deliveries_invoice_date"
    t.index ["invoice_id"], name: "index_invoice_deliveries_on_invoice_id"
    t.index ["organization_id"], name: "index_invoice_deliveries_on_organization_id"
    t.index ["recorded_by_id"], name: "index_invoice_deliveries_on_recorded_by_id"
    t.check_constraint "channel::text = ANY (ARRAY['email'::character varying::text, 'mail'::character varying::text, 'hand_delivery'::character varying::text, 'portal'::character varying::text, 'other'::character varying::text])", name: "check_invoice_deliveries_channel"
  end

  create_table "invoice_events", force: :cascade do |t|
    t.bigint "actor_id"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "invoice_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.bigint "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_invoice_events_on_actor_id"
    t.index ["invoice_id", "occurred_at", "id"], name: "idx_invoice_events_timeline"
    t.index ["invoice_id"], name: "index_invoice_events_on_invoice_id"
    t.index ["organization_id"], name: "index_invoice_events_on_organization_id"
  end

  create_table "invoice_line_items", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.bigint "invoice_id", null: false
    t.integer "position", default: 0, null: false
    t.decimal "quantity", precision: 12, scale: 2, default: "1.0", null: false
    t.decimal "rate", precision: 12, scale: 2, default: "0.0", null: false
    t.date "service_date"
    t.datetime "updated_at", null: false
    t.index ["invoice_id", "position"], name: "index_invoice_line_items_on_invoice_id_and_position"
    t.index ["invoice_id"], name: "index_invoice_line_items_on_invoice_id"
  end

  create_table "invoice_number_sequences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "invoice_billing_profile_id", null: false
    t.integer "last_number", default: 0, null: false
    t.integer "sequence_year", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_billing_profile_id", "sequence_year"], name: "idx_invoice_number_sequences_unique_year", unique: true
    t.index ["invoice_billing_profile_id"], name: "index_invoice_number_sequences_on_invoice_billing_profile_id"
    t.check_constraint "last_number >= 0", name: "check_invoice_number_sequence_last_number"
    t.check_constraint "sequence_year >= 1900 AND sequence_year <= 9999", name: "check_invoice_number_sequence_year"
  end

  create_table "invoice_payments", force: :cascade do |t|
    t.decimal "amount", precision: 14, scale: 2, null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.bigint "invoice_id", null: false
    t.text "notes"
    t.bigint "organization_id", null: false
    t.string "payment_method", null: false
    t.date "received_on", null: false
    t.bigint "recorded_by_id"
    t.string "reference_number"
    t.text "reversal_reason"
    t.datetime "reversed_at"
    t.bigint "reversed_by_id"
    t.boolean "system_generated", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_id", "received_on"], name: "idx_invoice_payments_on_invoice_received"
    t.index ["invoice_id"], name: "index_invoice_payments_on_invoice_id"
    t.index ["organization_id"], name: "index_invoice_payments_on_organization_id"
    t.index ["recorded_by_id"], name: "index_invoice_payments_on_recorded_by_id"
    t.index ["reversed_by_id"], name: "index_invoice_payments_on_reversed_by_id"
    t.check_constraint "amount > 0::numeric", name: "check_invoice_payments_positive_amount"
    t.check_constraint "payment_method::text = ANY (ARRAY['cash'::character varying::text, 'check'::character varying::text, 'ach'::character varying::text, 'card'::character varying::text, 'wire'::character varying::text, 'adjustment'::character varying::text, 'legacy'::character varying::text, 'other'::character varying::text])", name: "check_invoice_payments_method"
    t.check_constraint "reversed_at IS NULL AND reversed_by_id IS NULL AND reversal_reason IS NULL OR reversed_at IS NOT NULL AND reversal_reason IS NOT NULL", name: "check_invoice_payments_reversal_fields"
  end

  create_table "invoice_recipients", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "address"
    t.bigint "company_id"
    t.datetime "created_at", null: false
    t.decimal "default_rate", precision: 12, scale: 2
    t.string "email"
    t.string "invoice_prefix"
    t.string "name", null: false
    t.text "notes"
    t.bigint "organization_id", null: false
    t.text "payment_terms"
    t.string "template_type", default: "standard", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "name"], name: "index_invoice_recipients_on_company_id_and_name"
    t.index ["company_id"], name: "index_invoice_recipients_on_company_id"
    t.index ["organization_id", "name"], name: "index_invoice_recipients_on_org_name"
    t.index ["organization_id"], name: "index_invoice_recipients_on_organization_id"
  end

  create_table "invoices", force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.datetime "archived_at"
    t.bigint "company_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "currency", default: "USD", null: false
    t.string "customer_reference"
    t.date "due_date"
    t.text "email_body"
    t.string "email_subject"
    t.datetime "generated_at"
    t.bigint "invoice_billing_profile_id", null: false
    t.date "invoice_date", null: false
    t.string "invoice_number", null: false
    t.bigint "invoice_recipient_id", null: false
    t.datetime "issued_at"
    t.string "legacy_status"
    t.text "notes"
    t.bigint "organization_id", null: false
    t.string "origin", default: "native", null: false
    t.datetime "paid_at"
    t.text "payment_terms"
    t.datetime "sent_at"
    t.date "service_period_end"
    t.date "service_period_start"
    t.jsonb "snapshot", default: {}, null: false
    t.integer "snapshot_version", default: 1, null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.string "status", default: "draft", null: false
    t.decimal "total_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.datetime "voided_at"
    t.index ["company_id", "invoice_date"], name: "index_invoices_on_company_id_and_invoice_date"
    t.index ["company_id", "status"], name: "index_invoices_on_company_id_and_status"
    t.index ["company_id"], name: "index_invoices_on_company_id"
    t.index ["created_by_id"], name: "index_invoices_on_created_by_id"
    t.index ["invoice_billing_profile_id", "invoice_number"], name: "index_invoices_on_billing_profile_invoice_number", unique: true
    t.index ["invoice_billing_profile_id", "status", "due_date"], name: "idx_invoices_on_profile_status_due_date"
    t.index ["invoice_billing_profile_id"], name: "index_invoices_on_invoice_billing_profile_id"
    t.index ["invoice_recipient_id"], name: "index_invoices_on_invoice_recipient_id"
    t.index ["organization_id", "archived", "invoice_date"], name: "idx_invoices_on_org_archive_invoice_date"
    t.index ["organization_id", "invoice_date"], name: "index_invoices_on_org_invoice_date"
    t.index ["organization_id", "status"], name: "index_invoices_on_org_status"
    t.index ["organization_id"], name: "index_invoices_on_organization_id"
    t.index ["updated_by_id"], name: "index_invoices_on_updated_by_id"
    t.check_constraint "origin::text = ANY (ARRAY['native'::character varying::text, 'imported'::character varying::text])", name: "check_invoices_origin"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'open'::character varying::text, 'voided'::character varying::text, 'uncollectible'::character varying::text])", name: "check_invoices_status"
  end

  create_table "loan_transactions", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.decimal "balance_after", precision: 10, scale: 2
    t.decimal "balance_before", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.bigint "employee_loan_id", null: false
    t.text "notes"
    t.bigint "pay_period_id"
    t.bigint "payroll_item_id"
    t.bigint "recorded_by_id"
    t.bigint "reverses_transaction_id"
    t.string "source", null: false
    t.date "transaction_date", null: false
    t.string "transaction_type", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_loan_id", "pay_period_id"], name: "idx_loan_txns_on_loan_and_pp"
    t.index ["employee_loan_id", "payroll_item_id"], name: "idx_loan_txns_unique_payroll_payment", unique: true, where: "(((source)::text = 'payroll'::text) AND ((transaction_type)::text = 'payment'::text) AND (payroll_item_id IS NOT NULL))"
    t.index ["employee_loan_id"], name: "index_loan_transactions_on_employee_loan_id"
    t.index ["pay_period_id"], name: "index_loan_transactions_on_pay_period_id"
    t.index ["payroll_item_id"], name: "index_loan_transactions_on_payroll_item_id"
    t.index ["recorded_by_id"], name: "index_loan_transactions_on_recorded_by_id"
    t.index [ "reverses_transaction_id" ], name: "index_loan_transactions_on_reverses_transaction_id", unique: true
    t.index ["transaction_type"], name: "index_loan_transactions_on_transaction_type"
    t.check_constraint "balance_before IS NULL AND balance_after IS NULL OR balance_before IS NOT NULL AND balance_after IS NOT NULL", name: "loan_transactions_balance_pair"
    t.check_constraint "source::text = ANY (ARRAY['opening_balance'::character varying::text, 'payroll'::character varying::text, 'manual'::character varying::text])", name: "loan_transactions_source_check"
  end

  create_table "non_employee_check_edits", force: :cascade do |t|
    t.jsonb "after", default: {}, null: false
    t.jsonb "before", default: {}, null: false
    t.jsonb "changed_fields", default: [], null: false
    t.datetime "created_at", null: false
    t.bigint "edited_by_id"
    t.bigint "non_employee_check_id", null: false
    t.string "reason"
    t.index ["created_at"], name: "index_non_employee_check_edits_on_created_at"
    t.index ["edited_by_id"], name: "index_non_employee_check_edits_on_edited_by_id"
    t.index ["non_employee_check_id"], name: "index_non_employee_check_edits_on_non_employee_check_id"
  end

  create_table "non_employee_check_line_items", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.datetime "created_at", null: false
    t.string "description", null: false
    t.bigint "non_employee_check_id", null: false
    t.integer "position", default: 0, null: false
    t.string "reference_number"
    t.string "service_period"
    t.datetime "updated_at", null: false
    t.index ["non_employee_check_id", "position"], name: "idx_ne_check_line_items_on_check_position"
    t.index ["non_employee_check_id"], name: "idx_ne_check_line_items_on_check"
    t.check_constraint "amount > 0::numeric", name: "non_employee_check_line_items_amount_positive"
  end

  create_table "non_employee_checks", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "auto_generated_type"
    t.string "check_number"
    t.string "check_type", null: false
    t.bigint "company_id", null: false
    t.string "confirmation_number"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.text "description"
    t.date "due_date"
    t.string "memo"
    t.bigint "pay_period_id"
    t.string "payable_to", null: false
    t.date "payment_date"
    t.string "payment_period_type", default: "none", null: false
    t.integer "print_count", default: 0, null: false
    t.datetime "printed_at"
    t.string "reference_number"
    t.integer "tax_month"
    t.integer "tax_quarter"
    t.integer "tax_year"
    t.datetime "updated_at", null: false
    t.string "void_reason"
    t.boolean "voided", default: false, null: false
    t.datetime "voided_at"
    t.index ["auto_generated_type"], name: "index_non_employee_checks_on_auto_generated_type", where: "(auto_generated_type IS NOT NULL)"
    t.index ["check_type"], name: "index_non_employee_checks_on_check_type"
    t.index ["company_id", "check_number"], name: "idx_ne_checks_on_company_check_num", unique: true, where: "(check_number IS NOT NULL)"
    t.index ["company_id", "payment_date"], name: "idx_ne_checks_on_company_payment_date"
    t.index ["company_id", "payment_period_type", "tax_year", "tax_month"], name: "idx_ne_checks_on_company_month"
    t.index ["company_id", "payment_period_type", "tax_year", "tax_quarter"], name: "idx_ne_checks_on_company_quarter"
    t.index ["company_id"], name: "index_non_employee_checks_on_company_id"
    t.index ["created_by_id"], name: "index_non_employee_checks_on_created_by_id"
    t.index ["pay_period_id", "company_id", "auto_generated_type"], name: "idx_unique_non_voided_auto_generated_per_period", unique: true, where: "((auto_generated_type IS NOT NULL) AND (voided = false))"
    t.index ["pay_period_id"], name: "index_non_employee_checks_on_pay_period_id"
    t.check_constraint "payment_period_type::text = ANY (ARRAY['none'::character varying::text, 'pay_period'::character varying::text, 'month'::character varying::text, 'quarter'::character varying::text, 'year'::character varying::text])", name: "non_employee_checks_payment_period_type_check"
    t.check_constraint "tax_month IS NULL OR tax_month >= 1 AND tax_month <= 12", name: "non_employee_checks_tax_month_check"
    t.check_constraint "tax_quarter IS NULL OR tax_quarter >= 1 AND tax_quarter <= 4", name: "non_employee_checks_tax_quarter_check"
  end

  create_table "organizations", force: :cascade do |t|
    t.integer "client_limit", default: 3
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "primary_company_id"
    t.string "slug", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["primary_company_id"], name: "index_organizations_on_primary_company_id"
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
    t.index ["status"], name: "index_organizations_on_status"
  end

  create_table "pay_component_tax_rules", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "additional_medicare_treatment", null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.bigint "company_id"
    t.string "component_key", null: false
    t.string "component_kind", null: false
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.date "effective_from", null: false
    t.date "effective_to"
    t.string "fit_treatment", null: false
    t.jsonb "form_941_mapping", default: {}, null: false
    t.string "gl_account_code"
    t.string "medicare_treatment", null: false
    t.string "register_presentation", default: "separate", null: false
    t.string "reimbursement_treatment", null: false
    t.string "retirement_treatment", null: false
    t.string "social_security_treatment", null: false
    t.string "source_name", null: false
    t.string "source_url"
    t.string "swica_treatment", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.jsonb "w2_gu_mapping", default: {}, null: false
    t.index ["approved_by_id"], name: "index_pay_component_tax_rules_on_approved_by_id"
    t.index ["company_id", "component_key", "effective_from"], name: "idx_component_rules_company_key_effective"
    t.index ["company_id"], name: "index_pay_component_tax_rules_on_company_id"
    t.index ["component_key", "effective_from"], name: "idx_component_rules_global_key_effective", where: "(company_id IS NULL)"
    t.check_constraint "effective_to IS NULL OR effective_to >= effective_from", name: "component_rules_effective_date_range"
  end

  create_table "pay_period_correction_events", force: :cascade do |t|
    t.string "action_type", null: false
    t.bigint "actor_id"
    t.string "actor_name"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "financial_snapshot", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "pay_period_id", null: false
    t.text "reason", null: false
    t.bigint "resulting_pay_period_id"
    t.datetime "updated_at", null: false
    t.index ["action_type"], name: "index_pay_period_correction_events_on_action_type"
    t.index ["actor_id"], name: "index_pay_period_correction_events_on_actor_id"
    t.index ["company_id"], name: "index_pay_period_correction_events_on_company_id"
    t.index ["created_at"], name: "index_pay_period_correction_events_on_created_at"
    t.index ["pay_period_id", "action_type"], name: "idx_ppce_pay_period_action"
    t.index ["pay_period_id"], name: "index_pay_period_correction_events_on_pay_period_id"
    t.index ["resulting_pay_period_id"], name: "index_pay_period_correction_events_on_resulting_pay_period_id"
  end

  create_table "pay_period_excluded_employees", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.bigint "excluded_by_id"
    t.bigint "pay_period_id", null: false
    t.string "reason"
    t.datetime "updated_at", null: false
    t.index ["employee_id"], name: "index_pay_period_excluded_employees_on_employee_id"
    t.index ["excluded_by_id"], name: "index_pay_period_excluded_employees_on_excluded_by_id"
    t.index ["pay_period_id", "employee_id"], name: "idx_pay_period_exclusions_on_period_employee", unique: true
    t.index ["pay_period_id"], name: "index_pay_period_excluded_employees_on_pay_period_id"
  end

  create_table "pay_periods", force: :cascade do |t|
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.datetime "calculated_at"
    t.bigint "calculated_by_id"
    t.datetime "committed_at"
    t.bigint "committed_by_id"
    t.bigint "company_id", null: false
    t.bigint "company_pay_schedule_id"
    t.bigint "company_workweek_id"
    t.string "correction_status"
    t.bigint "corrects_pay_period_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "cycle", default: "regular", null: false
    t.date "end_date", null: false
    t.boolean "includes_base_salary", default: true, null: false
    t.boolean "includes_recurring_items", default: true, null: false
    t.datetime "intake_stale_at"
    t.text "intake_stale_reason"
    t.bigint "intake_stale_session_id"
    t.text "notes"
    t.boolean "parallel_run", default: false, null: false
    t.date "pay_date", null: false
    t.string "run_purpose", default: "regular", null: false
    t.string "run_purpose_source", default: "legacy_system_default", null: false
    t.bigint "source_pay_period_id"
    t.date "start_date", null: false
    t.string "status", default: "draft"
    t.bigint "superseded_by_id"
    t.integer "tax_sync_attempts", default: 0, null: false
    t.string "tax_sync_idempotency_key"
    t.text "tax_sync_last_error"
    t.string "tax_sync_status", default: "pending"
    t.datetime "tax_synced_at"
    t.datetime "unapproved_at"
    t.bigint "unapproved_by_id"
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.index ["calculated_by_id"], name: "index_pay_periods_on_calculated_by_id"
    t.index ["committed_by_id"], name: "index_pay_periods_on_committed_by_id"
    t.index ["company_id", "end_date"], name: "index_pay_periods_on_company_id_and_end_date"
    t.index ["company_id", "parallel_run", "pay_date"], name: "idx_pay_periods_parallel_runs"
    t.index ["company_id", "run_purpose"], name: "idx_pay_periods_company_purpose"
    t.index ["company_id", "start_date"], name: "index_pay_periods_on_company_id_and_start_date"
    t.index ["company_id", "status"], name: "index_pay_periods_on_company_id_and_status"
    t.index ["company_id"], name: "index_pay_periods_on_company_id"
    t.index ["company_pay_schedule_id"], name: "index_pay_periods_on_company_pay_schedule_id"
    t.index ["company_workweek_id"], name: "index_pay_periods_on_company_workweek_id"
    t.index ["correction_status"], name: "index_pay_periods_on_correction_status"
    t.index ["corrects_pay_period_id"], name: "index_pay_periods_on_corrects_pay_period_id"
    t.index ["cycle"], name: "index_pay_periods_on_cycle"
    t.index ["intake_stale_session_id"], name: "idx_pay_periods_intake_stale_session"
    t.index ["source_pay_period_id"], name: "idx_pay_periods_unique_source_correction_run", unique: true, where: "((source_pay_period_id IS NOT NULL) AND ((correction_status)::text <> 'voided'::text))"
    t.index ["status"], name: "index_pay_periods_on_status"
    t.index ["superseded_by_id"], name: "idx_pay_periods_unique_superseded_by", unique: true, where: "(superseded_by_id IS NOT NULL)"
    t.index ["tax_sync_idempotency_key"], name: "index_pay_periods_on_tax_sync_idempotency_key", unique: true
    t.index ["tax_sync_status"], name: "index_pay_periods_on_tax_sync_status"
    t.index ["unapproved_by_id"], name: "index_pay_periods_on_unapproved_by_id"
    t.index ["voided_by_id"], name: "index_pay_periods_on_voided_by_id"
    t.check_constraint "cycle::text = ANY (ARRAY['regular'::character varying::text, 'supplemental'::character varying::text])", name: "pay_periods_cycle_check"
    t.check_constraint "intake_stale_at IS NULL AND intake_stale_reason IS NULL AND intake_stale_session_id IS NULL OR intake_stale_at IS NOT NULL AND NULLIF(btrim(intake_stale_reason), ''::text) IS NOT NULL AND intake_stale_session_id IS NOT NULL", name: "pay_periods_intake_stale_complete"
    t.check_constraint "parallel_run = false OR status::text <> 'committed'::text", name: "pay_periods_parallel_runs_not_committed"
    t.check_constraint "run_purpose::text <> 'off_cycle_tips'::text OR includes_base_salary = false", name: "pay_periods_off_cycle_tips_salary_check"
    t.check_constraint "run_purpose::text = ANY (ARRAY['regular'::character varying::text, 'off_cycle_tips'::character varying::text, 'bonus'::character varying::text, 'commission'::character varying::text, 'correction'::character varying::text, 'final'::character varying::text, 'adjustment'::character varying::text])", name: "pay_periods_run_purpose_check"
    t.check_constraint "run_purpose_source::text = ANY (ARRAY['operator_selected'::character varying::text, 'system_correction'::character varying::text, 'production_migration'::character varying::text, 'legacy_system_default'::character varying::text])", name: "pay_periods_run_purpose_source_check"
  end

  create_table "payroll_field_definitions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "amount_type", default: "fixed", null: false
    t.string "category", default: "other", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.decimal "default_amount", precision: 10, scale: 2
    t.decimal "default_percentage", precision: 8, scale: 4
    t.text "description"
    t.string "kind", null: false
    t.string "name", null: false
    t.string "payee_name"
    t.string "reference_number"
    t.string "reporting_group"
    t.boolean "show_in_payroll_grid", default: true, null: false
    t.integer "sort_order", default: 0, null: false
    t.string "tax_treatment", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active", "sort_order"], name: "idx_payroll_fields_company_active_order"
    t.index ["company_id", "name"], name: "idx_payroll_fields_company_name", unique: true
    t.index ["company_id", "reporting_group"], name: "idx_payroll_fields_company_reporting_group"
    t.index ["company_id"], name: "index_payroll_field_definitions_on_company_id"
  end

  create_table "payroll_filing_responsibilities", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "filing_type", null: false
    t.string "imported_payroll_inclusion", null: false
    t.text "notes"
    t.integer "quarter"
    t.string "responsible_party", null: false
    t.datetime "reviewed_at", null: false
    t.string "reviewed_by_email", null: false
    t.bigint "reviewed_by_id"
    t.string "reviewed_by_name", null: false
    t.string "reviewed_by_role", null: false
    t.date "source_cutoff_date"
    t.integer "tax_year", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "tax_year", "filing_type"], name: "idx_payroll_filing_responsibilities_annual", unique: true, where: "(quarter IS NULL)"
    t.index ["company_id", "tax_year", "quarter", "filing_type"], name: "idx_payroll_filing_responsibilities_quarterly", unique: true, where: "(quarter IS NOT NULL)"
    t.index ["company_id"], name: "index_payroll_filing_responsibilities_on_company_id"
    t.index ["reviewed_by_id"], name: "index_payroll_filing_responsibilities_on_reviewed_by_id"
    t.check_constraint "filing_type::text = 'w2_gu'::text AND quarter IS NULL OR (filing_type::text = ANY (ARRAY['form_941'::character varying, 'guam_withholding'::character varying, 'swica'::character varying]::text[])) AND quarter >= 1 AND quarter <= 4", name: "payroll_filing_responsibilities_period_check"
    t.check_constraint "filing_type::text = ANY (ARRAY['form_941'::character varying, 'guam_withholding'::character varying, 'swica'::character varying, 'w2_gu'::character varying]::text[])", name: "payroll_filing_responsibilities_type_check"
    t.check_constraint "imported_payroll_inclusion::text = ANY (ARRAY['included'::character varying, 'excluded'::character varying]::text[])", name: "payroll_filing_responsibilities_inclusion_check"
    t.check_constraint "responsible_party::text = ANY (ARRAY['external_provider'::character varying, 'cornerstone'::character varying]::text[])", name: "payroll_filing_responsibilities_party_check"
    t.check_constraint "tax_year >= 2000 AND tax_year <= 2200", name: "payroll_filing_responsibilities_year_check"
  end

  create_table "payroll_go_live_reviews", force: :cascade do |t|
    t.datetime "approved_at"
    t.jsonb "attestations", default: {}, null: false
    t.bigint "company_id", null: false
    t.string "company_setup_digest"
    t.text "company_setup_review_notes"
    t.datetime "company_setup_reviewed_at"
    t.bigint "company_setup_reviewed_by_id"
    t.string "company_setup_reviewed_by_name"
    t.string "company_setup_reviewed_by_email"
    t.string "company_setup_reviewed_by_role"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.date "effective_on", null: false
    t.bigint "historical_import_batch_id", null: false
    t.datetime "operations_signed_at"
    t.bigint "operations_signed_by_id"
    t.string "plan_digest", null: false
    t.text "review_notes"
    t.datetime "setup_applied_at"
    t.bigint "setup_applied_by_id"
    t.jsonb "setup_plan", default: {}, null: false
    t.jsonb "setup_summary", default: {}, null: false
    t.bigint "source_company_id", null: false
    t.string "status", default: "draft", null: false
    t.datetime "technical_signed_at"
    t.bigint "technical_signed_by_id"
    t.datetime "updated_at", null: false
    t.jsonb "validation_errors", default: [], null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["company_id"], name: "index_payroll_go_live_reviews_on_company_id", unique: true
    t.index ["company_setup_reviewed_by_id"], name: "idx_go_live_reviews_company_setup_reviewer"
    t.index ["created_by_id"], name: "index_payroll_go_live_reviews_on_created_by_id"
    t.index ["historical_import_batch_id"], name: "index_payroll_go_live_reviews_on_historical_import_batch_id", unique: true
    t.index ["operations_signed_by_id"], name: "index_payroll_go_live_reviews_on_operations_signed_by_id"
    t.index ["setup_applied_by_id"], name: "index_payroll_go_live_reviews_on_setup_applied_by_id"
    t.index ["source_company_id"], name: "index_payroll_go_live_reviews_on_source_company_id"
    t.index ["technical_signed_by_id"], name: "index_payroll_go_live_reviews_on_technical_signed_by_id"
    t.check_constraint "jsonb_typeof(setup_summary) = 'object'::text AND jsonb_typeof(setup_plan) = 'object'::text AND jsonb_typeof(attestations) = 'object'::text", name: "payroll_go_live_reviews_object_json_check"
    t.check_constraint "jsonb_typeof(warnings) = 'array'::text AND jsonb_typeof(validation_errors) = 'array'::text", name: "payroll_go_live_reviews_array_json_check"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'setup_applied'::character varying, 'approved'::character varying]::text[])", name: "payroll_go_live_reviews_status_check"
  end

  create_table "payroll_imports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "excel_filename"
    t.jsonb "matched_data", default: []
    t.bigint "pay_period_id", null: false
    t.bigint "payroll_intake_session_id"
    t.string "pdf_filename"
    t.jsonb "raw_data", default: {}
    t.string "status", default: "pending", null: false
    t.jsonb "unmatched_pdf_names", default: []
    t.datetime "updated_at", null: false
    t.jsonb "validation_errors", default: []
    t.index ["pay_period_id", "status"], name: "index_payroll_imports_on_pay_period_id_and_status"
    t.index ["pay_period_id"], name: "index_payroll_imports_on_pay_period_id"
    t.index ["payroll_intake_session_id"], name: "idx_payroll_imports_intake_session", unique: true
  end

  create_table "payroll_intake_documents", force: :cascade do |t|
    t.bigint "byte_size"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "document_type", null: false
    t.text "extracted_text"
    t.string "filename"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "payroll_intake_session_id", null: false
    t.integer "position", default: 0, null: false
    t.jsonb "raw_response", default: {}, null: false
    t.string "sha256"
    t.string "source_role", default: "legacy_source", null: false
    t.text "storage_reference"
    t.text "text_content"
    t.datetime "updated_at", null: false
    t.string "verification_error"
    t.string "verification_status", default: "legacy_unverified", null: false
    t.datetime "verified_at"
    t.index ["payroll_intake_session_id", "document_type"], name: "idx_payroll_intake_documents_session_type"
    t.index ["payroll_intake_session_id", "position"], name: "idx_payroll_intake_documents_session_position", unique: true
    t.index ["payroll_intake_session_id"], name: "idx_payroll_intake_documents_session"
    t.index ["storage_reference"], name: "idx_payroll_intake_documents_storage_reference", unique: true, where: "(storage_reference IS NOT NULL)"
    t.check_constraint "\"position\" >= 0", name: "payroll_intake_documents_position_nonnegative"
    t.check_constraint "source_role::text = ANY (ARRAY['pasted_email'::character varying, 'email_attachment'::character varying, 'revel_hours'::character varying, 'supplemental_workbook'::character varying, 'supporting_document'::character varying, 'legacy_source'::character varying]::text[])", name: "payroll_intake_documents_source_role"
    t.check_constraint "verification_status::text <> 'verified'::text OR byte_size > 0 AND sha256::text ~ '^[0-9a-f]{64}$'::text AND verified_at IS NOT NULL", name: "payroll_intake_documents_verified_fingerprint"
    t.check_constraint "verification_status::text = ANY (ARRAY['verified'::character varying, 'failed'::character varying, 'legacy_unverified'::character varying]::text[])", name: "payroll_intake_documents_verification_status"
  end

  create_table "payroll_intake_rows", force: :cascade do |t|
    t.bigint "applied_payroll_item_id"
    t.decimal "confidence", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.string "disposition", default: "pending", null: false
    t.text "disposition_reason"
    t.datetime "dispositioned_at"
    t.bigint "dispositioned_by_id"
    t.bigint "employee_id"
    t.boolean "excluded", default: false, null: false
    t.decimal "loan_deduction", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "match_confidence", precision: 5, scale: 4
    t.string "match_method"
    t.decimal "overtime_hours", precision: 8, scale: 2, default: "0.0", null: false
    t.bigint "payroll_intake_session_id", null: false
    t.integer "position", default: 0, null: false
    t.decimal "regular_hours", precision: 8, scale: 2, default: "0.0", null: false
    t.decimal "reported_tips", precision: 10, scale: 2, default: "0.0", null: false
    t.string "source_employee_name", null: false
    t.jsonb "source_payload", default: {}, null: false
    t.jsonb "staff_overrides", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.bigint "target_pay_period_id"
    t.decimal "tips_paid_out", precision: 10, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.jsonb "validation_errors", default: [], null: false
    t.jsonb "warnings", default: [], null: false
    t.decimal "week1_hours", precision: 8, scale: 2, default: "0.0", null: false
    t.decimal "week1_tips", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "week2_hours", precision: 8, scale: 2, default: "0.0", null: false
    t.decimal "week2_tips", precision: 10, scale: 2, default: "0.0", null: false
    t.index ["applied_payroll_item_id"], name: "index_payroll_intake_rows_on_applied_payroll_item_id"
    t.index ["dispositioned_by_id"], name: "idx_payroll_intake_rows_dispositioned_by"
    t.index ["employee_id"], name: "index_payroll_intake_rows_on_employee_id"
    t.index ["payroll_intake_session_id", "disposition"], name: "idx_payroll_intake_rows_session_disposition"
    t.index ["payroll_intake_session_id", "employee_id"], name: "idx_payroll_intake_rows_session_employee"
    t.index ["payroll_intake_session_id", "position"], name: "idx_payroll_intake_rows_session_position"
    t.index ["payroll_intake_session_id"], name: "idx_payroll_intake_rows_session"
    t.index ["status", "excluded"], name: "idx_payroll_intake_rows_status_excluded"
    t.index ["target_pay_period_id"], name: "idx_payroll_intake_rows_target_period"
    t.check_constraint "(disposition::text = ANY (ARRAY['pending'::character varying, 'included'::character varying]::text[])) OR NULLIF(btrim(disposition_reason), ''::text) IS NOT NULL", name: "payroll_intake_rows_reason_required"
    t.check_constraint "disposition::text = 'deferred'::text AND target_pay_period_id IS NOT NULL OR disposition::text <> 'deferred'::text AND target_pay_period_id IS NULL", name: "payroll_intake_rows_deferred_target"
    t.check_constraint "disposition::text = 'pending'::text OR dispositioned_at IS NOT NULL", name: "payroll_intake_rows_dispositioned_at"
    t.check_constraint "disposition::text = ANY (ARRAY['pending'::character varying, 'included'::character varying, 'excluded'::character varying, 'deferred'::character varying, 'informational'::character varying]::text[])", name: "payroll_intake_rows_disposition"
  end

  create_table "payroll_intake_sessions", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_id"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.text "error_message"
    t.jsonb "evidence_snapshot", default: {}, null: false
    t.string "import_hash", null: false
    t.string "package_id", null: false
    t.integer "package_revision", null: false
    t.string "package_schema_version", default: "legacy", null: false
    t.string "parser_version", null: false
    t.bigint "pay_period_id", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.string "source_label"
    t.string "source_type", null: false
    t.string "status", default: "draft", null: false
    t.datetime "superseded_at"
    t.bigint "superseded_by_user_id"
    t.bigint "supersedes_id"
    t.text "supersession_reason"
    t.jsonb "totals", default: {}, null: false
    t.datetime "updated_at", null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["applied_by_id"], name: "index_payroll_intake_sessions_on_applied_by_id"
    t.index ["company_id", "pay_period_id", "status"], name: "idx_payroll_intake_sessions_company_period_status"
    t.index ["company_id"], name: "index_payroll_intake_sessions_on_company_id"
    t.index ["created_by_id"], name: "index_payroll_intake_sessions_on_created_by_id"
    t.index ["package_id"], name: "index_payroll_intake_sessions_on_package_id", unique: true
    t.index ["pay_period_id", "package_revision"], name: "idx_payroll_intake_sessions_period_revision", unique: true
    t.index ["pay_period_id", "source_type", "import_hash"], name: "idx_payroll_intake_sessions_idempotency", unique: true
    t.index ["pay_period_id", "source_type"], name: "idx_payroll_intake_sessions_current_source", unique: true, where: "(superseded_at IS NULL)"
    t.index ["pay_period_id"], name: "index_payroll_intake_sessions_on_pay_period_id"
    t.index ["reviewed_by_id"], name: "index_payroll_intake_sessions_on_reviewed_by_id"
    t.index ["source_type", "status"], name: "idx_payroll_intake_sessions_source_status"
    t.index ["superseded_by_user_id"], name: "idx_payroll_intake_sessions_superseded_user"
    t.index ["supersedes_id"], name: "idx_payroll_intake_sessions_one_successor", unique: true, where: "(supersedes_id IS NOT NULL)"
    t.check_constraint "package_revision > 0", name: "payroll_intake_sessions_revision_positive"
    t.check_constraint "supersedes_id IS NULL AND supersession_reason IS NULL OR supersedes_id IS NOT NULL AND NULLIF(btrim(supersession_reason), ''::text) IS NOT NULL", name: "payroll_intake_sessions_supersession_complete"
  end

  create_table "payroll_item_deductions", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.bigint "deduction_type_id", null: false
    t.bigint "employee_loan_id"
    t.string "label", null: false
    t.jsonb "loan_schedule_snapshot", default: {}, null: false
    t.bigint "payroll_item_id", null: false
    t.string "reporting_group"
    t.datetime "updated_at", null: false
    t.index ["deduction_type_id"], name: "index_payroll_item_deductions_on_deduction_type_id"
    t.index [ "employee_loan_id" ], name: "index_payroll_item_deductions_on_employee_loan_id"
    t.index ["payroll_item_id", "deduction_type_id"], name: "idx_pi_deductions_on_pi_and_dt", unique: true
    t.index ["payroll_item_id"], name: "index_payroll_item_deductions_on_payroll_item_id"
    t.index ["reporting_group"], name: "idx_payroll_item_deductions_reporting_group"
  end

  create_table "payroll_item_earnings", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.decimal "hours", precision: 8, scale: 2, default: "0.0"
    t.string "label", null: false
    t.bigint "payroll_item_id", null: false
    t.decimal "rate", precision: 12, scale: 6
    t.datetime "updated_at", null: false
    t.index ["payroll_item_id", "category", "label"], name: "idx_pi_earnings_on_pi_cat_label", unique: true
    t.index ["payroll_item_id"], name: "index_payroll_item_earnings_on_payroll_item_id"
  end

  create_table "payroll_item_field_entries", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.decimal "amount", precision: 10, scale: 2, default: "0.0", null: false
    t.string "category", default: "other", null: false
    t.datetime "created_at", null: false
    t.boolean "employee_paid", default: true, null: false
    t.boolean "employer_paid", default: false, null: false
    t.string "kind", null: false
    t.string "label", null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "notes"
    t.bigint "payroll_field_definition_id"
    t.bigint "payroll_item_id", null: false
    t.string "reporting_group"
    t.string "source", default: "employee_default", null: false
    t.string "tax_treatment", null: false
    t.datetime "updated_at", null: false
    t.index ["payroll_field_definition_id"], name: "idx_payroll_item_field_entries_definition"
    t.index ["payroll_item_id", "payroll_field_definition_id"], name: "idx_payroll_item_field_entries_unique_definition", unique: true
    t.index ["payroll_item_id", "tax_treatment"], name: "idx_payroll_item_field_entries_treatment"
    t.index ["payroll_item_id"], name: "idx_payroll_item_field_entries_item"
    t.index ["reporting_group"], name: "idx_payroll_item_field_entries_reporting_group"
  end

  create_table "payroll_items", force: :cascade do |t|
    t.decimal "additional_medicare_tax", precision: 12, scale: 2
    t.decimal "additional_medicare_taxable_wages", precision: 14, scale: 2
    t.decimal "additional_withholding", precision: 10, scale: 2, default: "0.0"
    t.decimal "additional_withholding_override", precision: 10, scale: 2
    t.bigint "annual_tax_config_id"
    t.decimal "bonus", precision: 10, scale: 2, default: "0.0"
    t.string "bonus_source"
    t.jsonb "calculation_context_snapshot", default: {}, null: false
    t.decimal "cash_tips_reported", precision: 14, scale: 2
    t.date "check_date"
    t.string "check_memo"
    t.string "check_number"
    t.integer "check_print_count", default: 0, null: false
    t.datetime "check_printed_at"
    t.bigint "company_id", null: false
    t.bigint "correction_for_payroll_item_id"
    t.text "correction_reason"
    t.datetime "created_at", null: false
    t.jsonb "custom_columns_data", default: {}
    t.jsonb "custom_deductions", default: [], null: false
    t.jsonb "custom_earnings", default: []
    t.bigint "employee_id", null: false
    t.decimal "employer_medicare_tax", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "employer_retirement_match", precision: 10, scale: 2, default: "0.0"
    t.decimal "employer_roth_retirement_match", precision: 10, scale: 2, default: "0.0"
    t.decimal "employer_social_security_tax", precision: 10, scale: 2, default: "0.0", null: false
    t.string "employment_type", null: false
    t.decimal "fit_taxable_wages", precision: 14, scale: 2
    t.decimal "gross_pay", precision: 12, scale: 2, default: "0.0"
    t.decimal "holiday_hours", precision: 8, scale: 2, default: "0.0"
    t.decimal "hours_worked", precision: 8, scale: 2, default: "0.0"
    t.string "import_source"
    t.decimal "imported_bonus", precision: 10, scale: 2
    t.decimal "insurance_payment", precision: 10, scale: 2, default: "0.0"
    t.decimal "loan_deduction", precision: 10, scale: 2, default: "0.0"
    t.decimal "loan_payment", precision: 10, scale: 2, default: "0.0"
    t.decimal "medicare_tax", precision: 10, scale: 2, default: "0.0"
    t.decimal "medicare_taxable_wages", precision: 14, scale: 2
    t.decimal "net_pay", precision: 12, scale: 2, default: "0.0"
    t.decimal "non_taxable_pay", precision: 12, scale: 2, default: "0.0"
    t.decimal "overtime_hours", precision: 8, scale: 2, default: "0.0"
    t.bigint "pay_period_id", null: false
    t.decimal "pay_rate", precision: 18, scale: 6, null: false
    t.jsonb "payroll_adjustments", default: [], null: false
    t.decimal "pto_hours", precision: 8, scale: 2, default: "0.0"
    t.decimal "qualified_overtime_compensation", precision: 14, scale: 2
    t.string "replaced_check_number"
    t.decimal "reported_tips", precision: 10, scale: 2, default: "0.0"
    t.string "reprint_of_check_number"
    t.decimal "retirement_payment", precision: 10, scale: 2, default: "0.0"
    t.jsonb "retirement_rule_snapshot", default: {}, null: false
    t.decimal "roth_retirement_payment", precision: 10, scale: 2, default: "0.0"
    t.decimal "salary_override", precision: 12, scale: 2
    t.decimal "scheduled_hours", precision: 8, scale: 2, default: "0.0", null: false
    t.decimal "service_charge_wages", precision: 14, scale: 2
    t.decimal "social_security_tax", precision: 10, scale: 2, default: "0.0"
    t.decimal "social_security_taxable_tips", precision: 14, scale: 2
    t.decimal "social_security_taxable_wages", precision: 14, scale: 2
    t.jsonb "tax_rule_snapshot", default: {}, null: false
    t.jsonb "timekeeping_context_snapshot", default: {}, null: false
    t.string "timekeeping_source"
    t.string "tip_pool"
    t.decimal "tips", precision: 10, scale: 2, default: "0.0"
    t.decimal "tips_paid_out", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "total_additions", precision: 12, scale: 2, default: "0.0"
    t.decimal "total_deductions", precision: 12, scale: 2, default: "0.0"
    t.datetime "updated_at", null: false
    t.string "void_reason"
    t.boolean "voided", default: false, null: false
    t.datetime "voided_at"
    t.bigint "voided_by_user_id"
    t.decimal "withholding_tax", precision: 10, scale: 2, default: "0.0"
    t.decimal "withholding_tax_adjustment", precision: 10, scale: 2
    t.decimal "withholding_tax_override", precision: 10, scale: 2
    t.decimal "ytd_gross", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_medicare_tax", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_net", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_retirement", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_roth_retirement", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_social_security_tax", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_withholding_tax", precision: 14, scale: 2, default: "0.0"
    t.index ["annual_tax_config_id"], name: "index_payroll_items_on_annual_tax_config_id"
    t.index ["check_number"], name: "index_payroll_items_on_check_number"
    t.index ["company_id", "check_number"], name: "index_payroll_items_on_company_check_number_unique", unique: true, where: "(check_number IS NOT NULL)"
    t.index ["company_id"], name: "index_payroll_items_on_company_id"
    t.index ["correction_for_payroll_item_id"], name: "index_payroll_items_on_correction_for_payroll_item_id"
    t.index ["employee_id"], name: "index_payroll_items_on_employee_id"
    t.index ["pay_period_id", "employee_id"], name: "index_payroll_items_on_pay_period_id_and_employee_id", unique: true
    t.index ["pay_period_id"], name: "index_payroll_items_on_pay_period_id"
    t.index ["replaced_check_number"], name: "index_payroll_items_on_replaced_check_number", where: "(replaced_check_number IS NOT NULL)"
    t.index ["reprint_of_check_number"], name: "index_payroll_items_on_reprint_of_check_number"
    t.index ["retirement_rule_snapshot"], name: "index_payroll_items_on_retirement_rule_snapshot", using: :gin
    t.index ["tax_rule_snapshot"], name: "index_payroll_items_on_tax_rule_snapshot", using: :gin
    t.index ["voided"], name: "index_payroll_items_on_voided"
    t.check_constraint "bonus_source IS NULL OR (bonus_source::text = ANY (ARRAY['manual'::character varying::text, 'mosa_revel'::character varying::text]))", name: "payroll_items_bonus_source_check"
    t.check_constraint "imported_bonus IS NULL OR imported_bonus >= 0::numeric", name: "payroll_items_imported_bonus_check"
    t.check_constraint "timekeeping_source IS NULL OR (timekeeping_source::text = ANY (ARRAY['schedule'::character varying::text, 'import'::character varying::text, 'manual'::character varying::text, 'correction_reference'::character varying::text, 'production_backfill'::character varying::text]))", name: "payroll_items_timekeeping_source_check"
  end

  create_table "payroll_liability_allocations", force: :cascade do |t|
    t.decimal "amount", precision: 14, scale: 2, null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "payroll_liability_entry_id", null: false
    t.bigint "payroll_liability_payment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_payroll_liability_allocations_on_company_id"
    t.index ["payroll_liability_entry_id"], name: "idx_liability_allocations_entry"
    t.index ["payroll_liability_payment_id", "payroll_liability_entry_id"], name: "idx_liability_allocations_unique_entry", unique: true
    t.check_constraint "amount <> 0::numeric", name: "liability_allocations_nonzero"
  end

  create_table "payroll_liability_due_dates", force: :cascade do |t|
    t.string "authority", null: false
    t.string "category", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.date "due_date", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "pay_period_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["company_id", "due_date"], name: "idx_liability_due_dates_company_due"
    t.index ["company_id"], name: "index_payroll_liability_due_dates_on_company_id"
    t.index ["pay_period_id", "category", "authority"], name: "idx_liability_due_dates_unique_obligation", unique: true
    t.index ["updated_by_id"], name: "index_payroll_liability_due_dates_on_updated_by_id"
  end

  create_table "payroll_liability_entries", force: :cascade do |t|
    t.decimal "amount", precision: 14, scale: 2, null: false
    t.string "authority", null: false
    t.string "category", null: false
    t.bigint "company_id", null: false
    t.string "component_key", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "pay_component_tax_rule_id"
    t.bigint "payroll_item_id"
    t.bigint "payroll_liability_posting_id", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "category"], name: "idx_liability_entries_company_category"
    t.index ["company_id"], name: "index_payroll_liability_entries_on_company_id"
    t.index ["pay_component_tax_rule_id"], name: "idx_liability_entries_component_rule"
    t.index ["payroll_item_id"], name: "index_payroll_liability_entries_on_payroll_item_id"
    t.index ["payroll_liability_posting_id", "payroll_item_id", "component_key"], name: "idx_liability_entries_unique_component", unique: true
    t.index ["payroll_liability_posting_id"], name: "idx_liability_entries_posting"
    t.check_constraint "amount <> 0::numeric", name: "liability_entries_nonzero_amount"
  end

  create_table "payroll_liability_evidences", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.bigint "company_id", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "filename", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "payroll_liability_payment_id", null: false
    t.string "sha256", null: false
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_payroll_liability_evidences_on_company_id"
    t.index ["created_by_id"], name: "index_payroll_liability_evidences_on_created_by_id"
    t.index ["payroll_liability_payment_id"], name: "idx_liability_evidence_payment"
    t.index ["storage_key"], name: "index_payroll_liability_evidences_on_storage_key", unique: true
    t.check_constraint "byte_size > 0", name: "liability_evidence_byte_size_positive"
    t.check_constraint "char_length(sha256::text) = 64", name: "liability_evidence_sha256_length"
  end

  create_table "payroll_liability_payments", force: :cascade do |t|
    t.decimal "amount", precision: 14, scale: 2, null: false
    t.string "authority", null: false
    t.string "category", null: false
    t.bigint "company_id", null: false
    t.string "confirmation_number"
    t.datetime "created_at", null: false
    t.string "idempotency_key", null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "notes"
    t.bigint "pay_period_id", null: false
    t.date "payment_date", null: false
    t.string "payment_method", null: false
    t.string "payment_type", default: "settlement", null: false
    t.text "reason"
    t.datetime "recorded_at", null: false
    t.bigint "recorded_by_id"
    t.bigint "source_payment_id"
    t.datetime "updated_at", null: false
    t.index ["company_id", "idempotency_key"], name: "idx_liability_payments_company_idempotency", unique: true
    t.index ["company_id", "payment_date"], name: "idx_liability_payments_company_date"
    t.index ["company_id"], name: "index_payroll_liability_payments_on_company_id"
    t.index ["pay_period_id", "authority", "category"], name: "idx_liability_payments_obligation"
    t.index ["pay_period_id"], name: "index_payroll_liability_payments_on_pay_period_id"
    t.index ["recorded_by_id"], name: "index_payroll_liability_payments_on_recorded_by_id"
    t.index ["source_payment_id"], name: "idx_liability_payments_one_reversal", unique: true, where: "(source_payment_id IS NOT NULL)"
    t.check_constraint "payment_type::text = 'settlement'::text AND amount > 0::numeric AND source_payment_id IS NULL OR payment_type::text = 'reversal'::text AND amount < 0::numeric AND source_payment_id IS NOT NULL", name: "liability_payments_sign_source_check"
    t.check_constraint "payment_type::text = ANY (ARRAY['settlement'::character varying::text, 'reversal'::character varying::text])", name: "liability_payments_type_check"
  end

  create_table "payroll_liability_postings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.jsonb "component_rule_snapshot", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "idempotency_key", null: false
    t.date "liability_date", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "pay_period_id", null: false
    t.datetime "posted_at", null: false
    t.bigint "posted_by_id"
    t.string "posting_type", null: false
    t.text "reason"
    t.bigint "source_posting_id"
    t.datetime "updated_at", null: false
    t.index ["company_id", "liability_date"], name: "idx_liability_postings_company_date"
    t.index ["company_id"], name: "index_payroll_liability_postings_on_company_id"
    t.index ["idempotency_key"], name: "idx_liability_postings_idempotency", unique: true
    t.index ["pay_period_id", "posting_type"], name: "idx_liability_postings_period_type"
    t.index ["pay_period_id"], name: "index_payroll_liability_postings_on_pay_period_id"
    t.index ["posted_by_id"], name: "index_payroll_liability_postings_on_posted_by_id"
    t.index ["source_posting_id"], name: "idx_liability_postings_one_reversal", unique: true, where: "(source_posting_id IS NOT NULL)"
    t.index ["source_posting_id"], name: "index_payroll_liability_postings_on_source_posting_id"
  end

  create_table "payroll_parallel_run_reviews", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.decimal "cornerstone_deductions", precision: 15, scale: 2, null: false
    t.integer "cornerstone_employee_count", null: false
    t.decimal "cornerstone_gross_pay", precision: 15, scale: 2, null: false
    t.decimal "cornerstone_net_pay", precision: 15, scale: 2, null: false
    t.decimal "cornerstone_taxes", precision: 15, scale: 2, null: false
    t.datetime "created_at", null: false
    t.jsonb "differences", default: {}, null: false
    t.text "notes"
    t.bigint "pay_period_id", null: false
    t.bigint "payroll_go_live_review_id", null: false
    t.bigint "recorded_by_id"
    t.string "result", null: false
    t.decimal "source_deductions", precision: 15, scale: 2, null: false
    t.integer "source_employee_count", null: false
    t.decimal "source_gross_pay", precision: 15, scale: 2, null: false
    t.decimal "source_net_pay", precision: 15, scale: 2, null: false
    t.string "source_system", default: "quickbooks", null: false
    t.decimal "source_taxes", precision: 15, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_payroll_parallel_run_reviews_on_company_id"
    t.index ["pay_period_id"], name: "index_payroll_parallel_run_reviews_on_pay_period_id", unique: true
    t.index ["payroll_go_live_review_id", "id"], name: "idx_parallel_reviews_chronological"
    t.index ["payroll_go_live_review_id"], name: "idx_parallel_reviews_go_live"
    t.index ["recorded_by_id"], name: "index_payroll_parallel_run_reviews_on_recorded_by_id"
    t.check_constraint "jsonb_typeof(differences) = 'object'::text", name: "payroll_parallel_run_reviews_differences_check"
    t.check_constraint "result::text = ANY (ARRAY['pass'::character varying, 'fail'::character varying]::text[])", name: "payroll_parallel_run_reviews_result_check"
    t.check_constraint "source_system::text = 'quickbooks'::text", name: "payroll_parallel_run_reviews_source_check"
  end

  create_table "payroll_reminder_configs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.integer "days_before_due", default: 3, null: false
    t.boolean "enabled", default: false, null: false
    t.jsonb "recipients", default: [], null: false
    t.boolean "send_overdue_alerts", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_payroll_reminder_configs_on_company_id", unique: true
  end

  create_table "payroll_reminder_logs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.date "expected_pay_date"
    t.bigint "pay_period_id"
    t.jsonb "recipients_snapshot", default: [], null: false
    t.string "reminder_type", null: false
    t.datetime "sent_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "pay_period_id", "reminder_type"], name: "idx_reminder_logs_period_unique", unique: true, where: "(pay_period_id IS NOT NULL)"
    t.index ["company_id", "reminder_type", "expected_pay_date"], name: "idx_reminder_logs_create_unique", unique: true, where: "((pay_period_id IS NULL) AND (expected_pay_date IS NOT NULL))"
    t.index ["company_id"], name: "index_payroll_reminder_logs_on_company_id"
    t.index ["pay_period_id"], name: "index_payroll_reminder_logs_on_pay_period_id"
  end

  create_table "payroll_review_packages", force: :cascade do |t|
    t.text "approval_acknowledgement"
    t.string "approval_evidence_reference"
    t.string "approval_method"
    t.text "approval_notes"
    t.bigint "approval_recorded_by_id"
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.string "calculation_checksum", null: false
    t.jsonb "calculation_snapshot", default: {}, null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "generated_at", null: false
    t.bigint "generated_by_id"
    t.bigint "pay_period_id", null: false
    t.integer "revision", null: false
    t.string "schema_version", default: "v1", null: false
    t.jsonb "source_manifest", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "superseded_at"
    t.text "supersession_reason"
    t.datetime "updated_at", null: false
    t.index ["approval_recorded_by_id"], name: "index_payroll_review_packages_on_approval_recorded_by_id"
    t.index ["approved_by_id"], name: "index_payroll_review_packages_on_approved_by_id"
    t.index ["calculation_checksum"], name: "idx_payroll_review_packages_checksum"
    t.index ["company_id"], name: "index_payroll_review_packages_on_company_id"
    t.index ["generated_by_id"], name: "index_payroll_review_packages_on_generated_by_id"
    t.index ["pay_period_id", "revision"], name: "idx_payroll_review_packages_period_revision", unique: true
    t.index ["pay_period_id"], name: "idx_payroll_review_packages_current", unique: true, where: "(superseded_at IS NULL)"
    t.index ["pay_period_id"], name: "index_payroll_review_packages_on_pay_period_id"
    t.check_constraint "approval_method IS NULL OR (approval_method::text = ANY (ARRAY['client_portal'::character varying, 'email_attestation'::character varying]::text[]))", name: "payroll_review_packages_approval_method_check"
    t.check_constraint "revision > 0", name: "payroll_review_packages_revision_positive"
    t.check_constraint "status::text = 'approved'::text AND approved_at IS NOT NULL AND approved_by_id IS NOT NULL AND approval_recorded_by_id IS NOT NULL AND approval_method IS NOT NULL AND approval_acknowledgement::text = 'I approve this exact payroll review revision for processing.'::text AND (approval_method::text <> 'email_attestation'::text OR NULLIF(btrim(approval_evidence_reference::text), ''::text) IS NOT NULL) AND (approval_method::text <> 'client_portal'::text OR approved_by_id = approval_recorded_by_id) OR status::text = 'pending'::text AND approved_at IS NULL AND approved_by_id IS NULL AND approval_recorded_by_id IS NULL AND approval_method IS NULL AND approval_acknowledgement IS NULL OR status::text = 'superseded'::text", name: "payroll_review_packages_approval_shape"
    t.check_constraint "status::text = 'superseded'::text AND superseded_at IS NOT NULL AND NULLIF(btrim(supersession_reason), ''::text) IS NOT NULL OR status::text <> 'superseded'::text AND superseded_at IS NULL AND supersession_reason IS NULL", name: "payroll_review_packages_supersession_shape"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying, 'superseded'::character varying]::text[])", name: "payroll_review_packages_status_check"
  end

  create_table "payroll_time_allocations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "daily_time_record_id", null: false
    t.bigint "employee_id", null: false
    t.decimal "holiday_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.string "ledger_key", default: "authoritative", null: false
    t.decimal "overtime_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.bigint "payroll_item_id", null: false
    t.decimal "pto_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.decimal "regular_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.decimal "scheduled_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.date "work_date", null: false
    t.index ["company_id"], name: "index_payroll_time_allocations_on_company_id"
    t.index ["daily_time_record_id"], name: "index_payroll_time_allocations_on_daily_time_record_id"
    t.index ["employee_id", "work_date", "ledger_key"], name: "idx_payroll_time_allocations_employee_day"
    t.index ["employee_id"], name: "index_payroll_time_allocations_on_employee_id"
    t.index ["payroll_item_id", "daily_time_record_id"], name: "idx_payroll_time_allocations_unique", unique: true
    t.index ["payroll_item_id"], name: "index_payroll_time_allocations_on_payroll_item_id"
    t.check_constraint "ledger_key::text = ANY (ARRAY['authoritative'::character varying::text, 'parallel'::character varying::text, 'test'::character varying::text, 'historical'::character varying::text])", name: "payroll_time_allocations_ledger_check"
    t.check_constraint "scheduled_hours >= 0::numeric AND regular_hours >= 0::numeric AND overtime_hours >= 0::numeric AND pto_hours >= 0::numeric AND holiday_hours >= 0::numeric", name: "payroll_time_allocations_hours_check"
    t.check_constraint "source::text = ANY (ARRAY['schedule'::character varying::text, 'import'::character varying::text, 'manual'::character varying::text, 'correction_reference'::character varying::text, 'production_backfill'::character varying::text])", name: "payroll_time_allocations_source_check"
  end

  create_table "printer_profiles", force: :cascade do |t|
    t.jsonb "check_layout_config", default: {}, null: false
    t.decimal "check_offset_x", precision: 5, scale: 3, default: "0.0", null: false
    t.decimal "check_offset_y", precision: 5, scale: 3, default: "0.0", null: false
    t.string "check_stock_type", default: "top_check", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "is_default", default: false, null: false
    t.string "name", null: false
    t.text "notes"
    t.bigint "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "name"], name: "index_printer_profiles_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_printer_profiles_on_organization_id"
    t.index ["organization_id"], name: "index_printer_profiles_one_default_per_organization", unique: true, where: "(is_default = true)"
  end

  create_table "punch_entries", force: :cascade do |t|
    t.integer "card_day"
    t.time "clock_in"
    t.time "clock_out"
    t.float "confidence"
    t.datetime "created_at", null: false
    t.date "date"
    t.string "day_of_week", limit: 3
    t.float "hours_worked"
    t.time "in3"
    t.time "lunch_in"
    t.time "lunch_out"
    t.boolean "manually_edited", default: false
    t.text "notes"
    t.time "out3"
    t.integer "review_state", default: 0, null: false
    t.datetime "reviewed_at"
    t.string "reviewed_by_name"
    t.bigint "timecard_id", null: false
    t.datetime "updated_at", null: false
    t.index ["timecard_id"], name: "index_punch_entries_on_timecard_id"
  end

  create_table "quarterly_compliance_packets", force: :cascade do |t|
    t.bigint "assigned_to_id"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.date "internal_target_date", null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "notes"
    t.date "official_due_date", null: false
    t.integer "quarter", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.string "status", default: "not_started", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["assigned_to_id"], name: "index_quarterly_compliance_packets_on_assigned_to_id"
    t.index ["company_id", "year", "quarter"], name: "idx_qc_packets_company_year_quarter", unique: true
    t.index ["company_id"], name: "index_quarterly_compliance_packets_on_company_id"
    t.index ["reviewed_by_id"], name: "index_quarterly_compliance_packets_on_reviewed_by_id"
    t.check_constraint "quarter >= 1 AND quarter <= 4", name: "qc_packets_quarter_check"
  end

  create_table "quarterly_compliance_tasks", force: :cascade do |t|
    t.bigint "assigned_to_id"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.date "due_date"
    t.datetime "filed_at"
    t.string "filing_confirmation_number"
    t.date "internal_target_date"
    t.text "notes"
    t.datetime "paid_at"
    t.decimal "payment_amount", precision: 12, scale: 2
    t.string "payment_confirmation_number"
    t.boolean "proof_attached", default: false, null: false
    t.bigint "quarterly_compliance_packet_id", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.string "status", default: "not_started", null: false
    t.string "task_type", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_to_id"], name: "index_quarterly_compliance_tasks_on_assigned_to_id"
    t.index ["quarterly_compliance_packet_id", "task_type"], name: "idx_qc_tasks_packet_type", unique: true
    t.index ["quarterly_compliance_packet_id"], name: "idx_qc_tasks_packet"
    t.index ["reviewed_by_id"], name: "index_quarterly_compliance_tasks_on_reviewed_by_id"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "tax_brackets", force: :cascade do |t|
    t.integer "bracket_order", null: false
    t.datetime "created_at", null: false
    t.bigint "filing_status_config_id", null: false
    t.decimal "max_income", precision: 12, scale: 2
    t.decimal "min_income", precision: 12, scale: 2, null: false
    t.decimal "rate", precision: 6, scale: 5, null: false
    t.datetime "updated_at", null: false
    t.index ["filing_status_config_id", "bracket_order"], name: "idx_tax_brackets_order_unique", unique: true
    t.index ["filing_status_config_id"], name: "index_tax_brackets_on_filing_status_config_id"
  end

  create_table "tax_config_audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "annual_tax_config_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.string "field_name"
    t.string "ip_address"
    t.text "new_value"
    t.text "old_value"
    t.bigint "user_id"
    t.index ["annual_tax_config_id", "created_at"], name: "idx_audit_logs_config_time"
    t.index ["annual_tax_config_id"], name: "index_tax_config_audit_logs_on_annual_tax_config_id"
    t.index ["created_at"], name: "index_tax_config_audit_logs_on_created_at"
  end

  create_table "tax_tables", force: :cascade do |t|
    t.decimal "additional_medicare_rate", precision: 6, scale: 5, default: "0.009"
    t.decimal "additional_medicare_threshold", precision: 12, scale: 2, default: "200000.0"
    t.decimal "allowance_amount", precision: 10, scale: 2
    t.jsonb "bracket_data", default: [], null: false
    t.datetime "created_at", null: false
    t.string "filing_status", null: false
    t.decimal "medicare_rate", precision: 6, scale: 5, default: "0.0145", null: false
    t.string "pay_frequency", null: false
    t.decimal "ss_rate", precision: 6, scale: 5, default: "0.062", null: false
    t.decimal "ss_wage_base", precision: 12, scale: 2, null: false
    t.decimal "standard_deduction", precision: 10, scale: 2, default: "0.0"
    t.integer "tax_year", null: false
    t.datetime "updated_at", null: false
    t.index ["tax_year", "filing_status", "pay_frequency"], name: "idx_tax_tables_year_status_frequency", unique: true
  end

  create_table "time_tracking_employee_mappings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.string "source_display_name"
    t.string "source_email"
    t.string "source_user_id", null: false
    t.uuid "source_user_uuid"
    t.bigint "time_tracking_source_id", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "time_tracking_source_id", "employee_id"], name: "idx_time_tracking_mappings_unique_employee", unique: true, where: "(source_user_uuid IS NOT NULL)"
    t.index ["company_id", "time_tracking_source_id", "source_user_id"], name: "idx_time_tracking_mappings_unique_source_user", unique: true
    t.index ["company_id", "time_tracking_source_id", "source_user_uuid"], name: "idx_time_tracking_mappings_unique_source_uuid", unique: true, where: "(source_user_uuid IS NOT NULL)"
    t.index ["company_id"], name: "index_time_tracking_employee_mappings_on_company_id"
    t.index ["employee_id"], name: "index_time_tracking_employee_mappings_on_employee_id"
    t.index ["time_tracking_source_id"], name: "idx_on_time_tracking_source_id_27610db0b2"
  end

  create_table "time_tracking_entry_allocations", force: :cascade do |t|
    t.jsonb "category_snapshot", default: {}, null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.string "line_key", null: false
    t.date "original_work_date", null: false
    t.decimal "overtime_hours", precision: 10, scale: 2, null: false
    t.bigint "pay_period_id", null: false
    t.bigint "payroll_item_id", null: false
    t.decimal "regular_hours", precision: 10, scale: 2, null: false
    t.string "source_kind", null: false
    t.string "source_time_entry_id", null: false
    t.string "source_user_id", null: false
    t.uuid "source_user_uuid"
    t.bigint "time_tracking_import_id", null: false
    t.bigint "time_tracking_source_id", null: false
    t.decimal "total_hours", precision: 10, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_time_tracking_entry_allocations_on_company_id"
    t.index ["employee_id"], name: "index_time_tracking_entry_allocations_on_employee_id"
    t.index ["pay_period_id", "employee_id"], name: "idx_time_tracking_allocations_period_employee"
    t.index ["pay_period_id"], name: "index_time_tracking_entry_allocations_on_pay_period_id"
    t.index ["payroll_item_id"], name: "index_time_tracking_entry_allocations_on_payroll_item_id"
    t.index ["time_tracking_import_id", "source_time_entry_id", "line_key"], name: "idx_time_tracking_allocations_unique_line", unique: true
    t.index ["time_tracking_import_id"], name: "idx_on_time_tracking_import_id_2296efcf6f"
    t.index ["time_tracking_source_id", "source_time_entry_id"], name: "idx_time_tracking_allocations_source_entry"
    t.index ["time_tracking_source_id"], name: "idx_on_time_tracking_source_id_73a6f85c95"
    t.check_constraint "source_kind::text = ANY (ARRAY['current'::character varying::text, 'carryover'::character varying::text, 'correction'::character varying::text])", name: "time_tracking_entry_allocations_source_kind_check"
    t.check_constraint "total_hours = (regular_hours + overtime_hours)", name: "time_tracking_entry_allocations_hours_reconcile"
  end

  create_table "time_tracking_imports", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_id"
    t.string "contract_version"
    t.datetime "created_at", null: false
    t.date "end_date", null: false
    t.string "external_batch_checksum"
    t.string "external_batch_id"
    t.date "fetch_end_date", null: false
    t.date "fetch_start_date", null: false
    t.text "negative_adjustment_acknowledgement"
    t.bigint "pay_period_id", null: false
    t.jsonb "processed_payload", default: {}, null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "reconciled_at"
    t.bigint "reconciled_by_id"
    t.jsonb "reconciliation_exceptions", default: [], null: false
    t.text "reconciliation_note"
    t.datetime "source_cutoff_at"
    t.string "source_payload_hash", null: false
    t.datetime "source_processing_event_occurred_at"
    t.string "source_processing_status"
    t.text "source_processing_sync_error"
    t.datetime "source_processing_synced_at"
    t.date "start_date", null: false
    t.string "status", default: "previewed", null: false
    t.bigint "time_tracking_source_id", null: false
    t.datetime "updated_at", null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["applied_by_id"], name: "index_time_tracking_imports_on_applied_by_id"
    t.index ["pay_period_id", "time_tracking_source_id", "start_date", "end_date", "source_payload_hash"], name: "idx_time_tracking_imports_idempotency", unique: true
    t.index ["pay_period_id"], name: "index_time_tracking_imports_on_pay_period_id"
    t.index ["reconciled_by_id"], name: "index_time_tracking_imports_on_reconciled_by_id"
    t.index ["source_processing_status"], name: "index_time_tracking_imports_on_source_processing_status"
    t.index ["time_tracking_source_id", "external_batch_id"], name: "idx_time_tracking_imports_unique_external_batch", unique: true, where: "(external_batch_id IS NOT NULL)"
    t.index ["time_tracking_source_id"], name: "index_time_tracking_imports_on_time_tracking_source_id"
    t.check_constraint "external_batch_id IS NULL AND external_batch_checksum IS NULL AND contract_version IS NULL AND source_cutoff_at IS NULL OR external_batch_id IS NOT NULL AND external_batch_checksum IS NOT NULL AND contract_version IS NOT NULL AND source_cutoff_at IS NOT NULL", name: "time_tracking_imports_batch_provenance_complete"
  end

  create_table "time_tracking_sources", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "base_url", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_synced_at"
    t.string "name", null: false
    t.text "shared_secret"
    t.string "source_type", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "name"], name: "index_time_tracking_sources_on_company_id_and_name", unique: true
    t.index ["company_id", "source_type"], name: "index_time_tracking_sources_on_company_id_and_source_type"
    t.index ["company_id"], name: "index_time_tracking_sources_on_company_id"
    t.index ["company_id"], name: "index_time_tracking_sources_one_active_per_company", unique: true, where: "(active = true)"
  end

  create_table "timecards", force: :cascade do |t|
    t.bigint "applied_employee_id"
    t.bigint "applied_payroll_item_id"
    t.datetime "applied_to_payroll_at"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "employee_name"
    t.string "image_hash"
    t.text "image_url"
    t.integer "ocr_status", default: 0, null: false
    t.float "overall_confidence"
    t.bigint "pay_period_id"
    t.date "period_end"
    t.date "period_start"
    t.text "preprocessed_image_url"
    t.jsonb "raw_ocr_response"
    t.datetime "reviewed_at"
    t.string "reviewed_by_name"
    t.datetime "updated_at", null: false
    t.index ["applied_employee_id"], name: "index_timecards_on_applied_employee_id"
    t.index ["applied_payroll_item_id"], name: "index_timecards_on_applied_payroll_item_id"
    t.index ["company_id", "image_hash"], name: "index_timecards_on_company_id_and_image_hash", unique: true, where: "(image_hash IS NOT NULL)"
    t.index ["company_id"], name: "index_timecards_on_company_id"
    t.index ["pay_period_id"], name: "index_timecards_on_pay_period_id"
  end

  create_table "transmittals", force: :cascade do |t|
    t.string "check_number_first"
    t.string "check_number_last"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.jsonb "custom_entries", default: []
    t.datetime "generated_at"
    t.jsonb "non_employee_check_numbers", default: {}
    t.jsonb "notes", default: []
    t.bigint "pay_period_id", null: false
    t.jsonb "payroll_check_numbers"
    t.string "preparer_name"
    t.jsonb "report_list", default: []
    t.date "transmittal_date"
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["company_id"], name: "index_transmittals_on_company_id"
    t.index ["created_by_id"], name: "index_transmittals_on_created_by_id"
    t.index ["pay_period_id"], name: "index_transmittals_on_pay_period_id", unique: true
    t.index ["updated_by_id"], name: "index_transmittals_on_updated_by_id"
  end

  create_table "user_invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.datetime "invited_at", null: false
    t.bigint "invited_by_id"
    t.string "name"
    t.integer "role", default: 2, null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "email", "accepted_at"], name: "idx_user_invitations_company_email"
    t.index ["company_id"], name: "index_user_invitations_on_company_id"
    t.index ["invited_by_id"], name: "index_user_invitations_on_invited_by_id"
    t.index ["token"], name: "index_user_invitations_on_token", unique: true
  end

  create_table "user_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "ip_address"
    t.string "jti", null: false
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.text "workos_access_token"
    t.index ["expires_at"], name: "index_user_sessions_on_expires_at"
    t.index ["jti"], name: "index_user_sessions_on_jti", unique: true
    t.index ["user_id"], name: "index_user_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "clerk_id"
    t.string "clerk_invitation_id"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "invitation_status", default: "accepted", null: false
    t.datetime "invited_at"
    t.bigint "invited_by_id"
    t.datetime "last_active_at"
    t.datetime "last_login_at"
    t.string "last_session_id_digest"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.boolean "platform_owner", default: false, null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "workos_id"
    t.index ["clerk_id"], name: "index_users_on_clerk_id", unique: true
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["organization_id"], name: "index_users_on_organization_id"
    t.index ["platform_owner"], name: "index_users_on_single_platform_owner", unique: true, where: "(platform_owner = true)"
    t.index ["workos_id"], name: "index_users_on_workos_id", unique: true
    t.check_constraint "NOT platform_owner OR role = 5 AND active = true AND lower(email::text) = 'shimizutechnology@gmail.com'::text", name: "users_platform_owner_identity"
  end

  create_table "w2_filing_readinesses", force: :cascade do |t|
    t.integer "blocking_count", default: 0, null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "findings", default: [], null: false
    t.datetime "marked_ready_at"
    t.bigint "marked_ready_by_id"
    t.text "notes"
    t.datetime "preflight_run_at"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.integer "warning_count", default: 0, null: false
    t.integer "year", null: false
    t.index ["company_id", "year"], name: "index_w2_filing_readinesses_on_company_id_and_year", unique: true
    t.index ["company_id"], name: "index_w2_filing_readinesses_on_company_id"
    t.index ["marked_ready_by_id"], name: "index_w2_filing_readinesses_on_marked_ready_by_id"
  end

  add_foreign_key "aire_payroll_acknowledgements", "time_tracking_imports"
  add_foreign_key "aire_payroll_entry_acknowledgements", "check_events"
  add_foreign_key "aire_payroll_entry_acknowledgements", "payroll_items"
  add_foreign_key "aire_payroll_entry_acknowledgements", "time_tracking_imports"
  add_foreign_key "audit_logs", "companies"
  add_foreign_key "audit_logs", "organizations"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "cable_connection_tickets", "companies"
  add_foreign_key "cable_connection_tickets", "users"
  add_foreign_key "check_events", "payroll_items"
  add_foreign_key "check_events", "users", on_delete: :nullify
  add_foreign_key "check_print_runs", "companies"
  add_foreign_key "check_print_runs", "pay_periods"
  add_foreign_key "check_print_runs", "users", column: "confirmed_by_id"
  add_foreign_key "check_print_runs", "users", column: "created_by_id"
  add_foreign_key "check_signoff_sheets", "companies"
  add_foreign_key "check_signoff_sheets", "pay_periods"
  add_foreign_key "check_signoff_sheets", "users", column: "updated_by_id"
  add_foreign_key "client_documents", "companies"
  add_foreign_key "client_documents", "employees"
  add_foreign_key "client_documents", "users", column: "uploaded_by_id"
  add_foreign_key "client_portal_messages", "client_documents", on_delete: :nullify
  add_foreign_key "client_portal_messages", "client_portal_threads"
  add_foreign_key "client_portal_messages", "companies"
  add_foreign_key "client_portal_messages", "users", column: "author_id", on_delete: :nullify
  add_foreign_key "client_portal_threads", "companies"
  add_foreign_key "client_portal_threads", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "client_portal_threads", "users", column: "resolved_by_id", on_delete: :nullify
  add_foreign_key "companies", "companies", column: "migration_source_company_id"
  add_foreign_key "companies", "historical_import_batches", column: "migration_source_batch_id"
  add_foreign_key "companies", "organizations"
  add_foreign_key "companies", "printer_profiles", column: "active_printer_profile_id"
  add_foreign_key "companies", "users", column: "migration_rehearsal_created_by_id"
  add_foreign_key "company_assignments", "companies"
  add_foreign_key "company_assignments", "users"
  add_foreign_key "company_pay_schedules", "companies"
  add_foreign_key "company_pay_schedules", "users", column: "confirmed_by_id"
  add_foreign_key "company_workweeks", "companies"
  add_foreign_key "company_workweeks", "users", column: "confirmed_by_id"
  add_foreign_key "company_ytd_totals", "companies"
  add_foreign_key "daily_time_records", "companies"
  add_foreign_key "daily_time_records", "daily_time_records", column: "supersedes_id"
  add_foreign_key "daily_time_records", "employee_work_profiles"
  add_foreign_key "daily_time_records", "employees"
  add_foreign_key "deduction_types", "companies"
  add_foreign_key "department_ytd_totals", "departments"
  add_foreign_key "departments", "companies"
  add_foreign_key "employee_change_requests", "companies"
  add_foreign_key "employee_change_requests", "employees"
  add_foreign_key "employee_change_requests", "users", column: "requested_by_id"
  add_foreign_key "employee_change_requests", "users", column: "reviewed_by_id"
  add_foreign_key "employee_configuration_review_resolutions", "companies", on_delete: :restrict
  add_foreign_key "employee_configuration_review_resolutions", "employees", on_delete: :restrict
  add_foreign_key "employee_configuration_review_resolutions", "users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "employee_deductions", "deduction_types"
  add_foreign_key "employee_deductions", "employees"
  add_foreign_key "employee_document_requirement_events", "client_documents", column: ["client_document_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_employee_document_requirement_events_document_tenant"
  add_foreign_key "employee_document_requirement_events", "companies"
  add_foreign_key "employee_document_requirement_events", "employee_document_requirements", column: ["employee_document_requirement_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_employee_document_requirement_events_requirement_tenant"
  add_foreign_key "employee_document_requirement_events", "employees", column: ["employee_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_employee_document_requirement_events_employee_tenant"
  add_foreign_key "employee_document_requirement_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "employee_document_requirements", "client_documents", column: ["client_document_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_employee_document_requirements_document_tenant"
  add_foreign_key "employee_document_requirements", "companies"
  add_foreign_key "employee_document_requirements", "employees", column: ["employee_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_employee_document_requirements_employee_tenant"
  add_foreign_key "employee_document_requirements", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "employee_document_requirements", "users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "employee_loans", "companies"
  add_foreign_key "employee_loans", "deduction_types"
  add_foreign_key "employee_loans", "employees"
  add_foreign_key "employee_loans", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "employee_loans", "users", column: "stopped_by_id", on_delete: :nullify
  add_foreign_key "employee_payroll_fields", "employee_loans"
  add_foreign_key "employee_payroll_fields", "employees"
  add_foreign_key "employee_payroll_fields", "payroll_field_definitions"
  add_foreign_key "employee_retirement_elections", "companies"
  add_foreign_key "employee_retirement_elections", "employees"
  add_foreign_key "employee_retirement_elections", "users", column: "created_by_id"
  add_foreign_key "employee_status_events", "companies"
  add_foreign_key "employee_status_events", "employees"
  add_foreign_key "employee_status_events", "users", column: "actor_id"
  add_foreign_key "employee_tipped_occupations", "employees", on_delete: :cascade
  add_foreign_key "employee_w4_elections", "companies", on_delete: :restrict
  add_foreign_key "employee_w4_elections", "employees", on_delete: :restrict
  add_foreign_key "employee_w4_elections", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "employee_wage_rates", "employees"
  add_foreign_key "employee_work_profiles", "companies"
  add_foreign_key "employee_work_profiles", "employees"
  add_foreign_key "employee_work_profiles", "users", column: "confirmed_by_id"
  add_foreign_key "employee_ytd_totals", "employees"
  add_foreign_key "employees", "companies"
  add_foreign_key "employees", "departments"
  add_foreign_key "employees", "employees", column: "previous_employee_id"
  add_foreign_key "filing_status_configs", "annual_tax_configs"
  add_foreign_key "form500_filings", "companies"
  add_foreign_key "form500_filings", "pay_periods"
  add_foreign_key "form500_filings", "users", column: "created_by_id"
  add_foreign_key "form500_filings", "users", column: "updated_by_id"
  add_foreign_key "general_transmittal_artifacts", "companies"
  add_foreign_key "general_transmittal_artifacts", "general_transmittals"
  add_foreign_key "general_transmittal_artifacts", "users", column: "created_by_id"
  add_foreign_key "general_transmittal_items", "general_transmittals", on_delete: :cascade
  add_foreign_key "general_transmittals", "companies"
  add_foreign_key "general_transmittals", "pay_periods"
  add_foreign_key "general_transmittals", "users", column: "created_by_id"
  add_foreign_key "general_transmittals", "users", column: "updated_by_id"
  add_foreign_key "historical_client_bootstrap_dispatches", "historical_client_bootstraps"
  add_foreign_key "historical_client_bootstrap_dispatches", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "historical_client_bootstraps", "companies"
  add_foreign_key "historical_client_bootstraps", "historical_import_batches"
  add_foreign_key "historical_client_bootstraps", "historical_import_batches", column: ["historical_import_batch_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_client_bootstraps_batch_tenant"
  add_foreign_key "historical_client_bootstraps", "users", column: "applied_by_id", on_delete: :nullify
  add_foreign_key "historical_client_bootstraps", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "historical_employee_ytd_balances", "companies"
  add_foreign_key "historical_employee_ytd_balances", "employees"
  add_foreign_key "historical_employee_ytd_balances", "historical_ytd_bridges"
  add_foreign_key "historical_employee_ytd_balances", "historical_ytd_bridges", column: ["historical_ytd_bridge_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_ytd_balances_bridge_tenant"
  add_foreign_key "historical_import_batches", "companies"
  add_foreign_key "historical_import_batches", "users", column: "applied_by_id", on_delete: :nullify
  add_foreign_key "historical_import_batches", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "historical_import_batches", "users", column: "locked_by_id", on_delete: :nullify
  add_foreign_key "historical_import_cutover_reviews", "companies"
  add_foreign_key "historical_import_cutover_reviews", "historical_import_batches"
  add_foreign_key "historical_import_cutover_reviews", "historical_import_batches", column: ["historical_import_batch_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_cutover_reviews_batch_tenant"
  add_foreign_key "historical_import_cutover_reviews", "users", column: "approved_by_id", on_delete: :nullify
  add_foreign_key "historical_import_cutover_reviews", "users", column: "verified_by_id", on_delete: :nullify
  add_foreign_key "historical_import_source_files", "companies"
  add_foreign_key "historical_import_source_files", "historical_import_batches"
  add_foreign_key "historical_import_source_files", "users", column: "uploaded_by_id", on_delete: :nullify
  add_foreign_key "historical_pay_periods", "companies"
  add_foreign_key "historical_pay_periods", "historical_import_batches"
  add_foreign_key "historical_paycheck_adjustment_events", "companies"
  add_foreign_key "historical_paycheck_adjustment_events", "historical_paycheck_adjustments"
  add_foreign_key "historical_paycheck_adjustment_events", "historical_paycheck_adjustments", column: ["historical_paycheck_adjustment_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_adjustment_events_tenant"
  add_foreign_key "historical_paycheck_adjustment_events", "historical_ytd_bridges", column: ["historical_ytd_bridge_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_adjustment_events_bridge_tenant"
  add_foreign_key "historical_paycheck_adjustment_events", "users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "historical_paycheck_adjustments", "companies"
  add_foreign_key "historical_paycheck_adjustments", "historical_paycheck_adjustments", column: ["reverses_adjustment_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_adjustments_reversal_tenant"
  add_foreign_key "historical_paycheck_adjustments", "historical_paychecks"
  add_foreign_key "historical_paycheck_adjustments", "historical_paychecks", column: ["historical_paycheck_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_adjustments_paycheck_tenant"
  add_foreign_key "historical_paycheck_adjustments", "users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "historical_paychecks", "companies"
  add_foreign_key "historical_paychecks", "employees"
  add_foreign_key "historical_paychecks", "historical_import_batches"
  add_foreign_key "historical_paychecks", "historical_pay_periods"
  add_foreign_key "historical_paychecks", "historical_workers"
  add_foreign_key "historical_tax_wage_reports", "companies"
  add_foreign_key "historical_tax_wage_reports", "historical_import_batches"
  add_foreign_key "historical_tax_wage_reports", "historical_import_batches", column: ["historical_import_batch_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_tax_reports_batch_tenant"
  add_foreign_key "historical_tax_wage_reports", "historical_import_source_files"
  add_foreign_key "historical_workers", "companies"
  add_foreign_key "historical_workers", "employees"
  add_foreign_key "historical_workers", "historical_import_batches"
  add_foreign_key "historical_ytd_bridges", "companies"
  add_foreign_key "historical_ytd_bridges", "historical_client_bootstraps"
  add_foreign_key "historical_ytd_bridges", "historical_import_batches"
  add_foreign_key "historical_ytd_bridges", "historical_import_batches", column: ["historical_import_batch_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_ytd_bridges_batch_tenant"
  add_foreign_key "historical_ytd_bridges", "historical_ytd_bridges", column: ["supersedes_historical_ytd_bridge_id", "company_id"], primary_key: ["id", "company_id"], name: "fk_historical_ytd_bridges_supersedes_tenant"
  add_foreign_key "historical_ytd_bridges", "users", column: "applied_by_id", on_delete: :restrict
  add_foreign_key "historical_ytd_bridges", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "invoice_artifacts", "invoices"
  add_foreign_key "invoice_artifacts", "organizations"
  add_foreign_key "invoice_artifacts", "users", column: "created_by_id"
  add_foreign_key "invoice_billing_profiles", "organizations"
  add_foreign_key "invoice_chat_messages", "invoice_chat_sessions", on_delete: :cascade
  add_foreign_key "invoice_chat_sessions", "companies"
  add_foreign_key "invoice_chat_sessions", "invoice_recipients"
  add_foreign_key "invoice_chat_sessions", "invoices"
  add_foreign_key "invoice_chat_sessions", "organizations"
  add_foreign_key "invoice_chat_sessions", "users", column: "created_by_id"
  add_foreign_key "invoice_chat_sessions", "users", column: "updated_by_id"
  add_foreign_key "invoice_credit_notes", "invoices"
  add_foreign_key "invoice_credit_notes", "organizations"
  add_foreign_key "invoice_credit_notes", "users", column: "issued_by_id"
  add_foreign_key "invoice_credit_notes", "users", column: "voided_by_id"
  add_foreign_key "invoice_deliveries", "invoice_artifacts"
  add_foreign_key "invoice_deliveries", "invoices"
  add_foreign_key "invoice_deliveries", "organizations"
  add_foreign_key "invoice_deliveries", "users", column: "recorded_by_id"
  add_foreign_key "invoice_events", "invoices"
  add_foreign_key "invoice_events", "organizations"
  add_foreign_key "invoice_events", "users", column: "actor_id"
  add_foreign_key "invoice_line_items", "invoices"
  add_foreign_key "invoice_number_sequences", "invoice_billing_profiles"
  add_foreign_key "invoice_payments", "invoices"
  add_foreign_key "invoice_payments", "organizations"
  add_foreign_key "invoice_payments", "users", column: "recorded_by_id"
  add_foreign_key "invoice_payments", "users", column: "reversed_by_id"
  add_foreign_key "invoice_recipients", "companies"
  add_foreign_key "invoice_recipients", "organizations"
  add_foreign_key "invoices", "companies"
  add_foreign_key "invoices", "invoice_billing_profiles"
  add_foreign_key "invoices", "invoice_recipients"
  add_foreign_key "invoices", "organizations"
  add_foreign_key "invoices", "users", column: "created_by_id"
  add_foreign_key "invoices", "users", column: "updated_by_id"
  add_foreign_key "loan_transactions", "employee_loans"
  add_foreign_key "loan_transactions", "pay_periods"
  add_foreign_key "loan_transactions", "payroll_items"
  add_foreign_key "loan_transactions", "users", column: "recorded_by_id", on_delete: :nullify
  add_foreign_key "non_employee_check_edits", "non_employee_checks", on_delete: :cascade
  add_foreign_key "non_employee_check_edits", "users", column: "edited_by_id"
  add_foreign_key "non_employee_check_line_items", "non_employee_checks", on_delete: :cascade
  add_foreign_key "non_employee_checks", "companies"
  add_foreign_key "non_employee_checks", "pay_periods"
  add_foreign_key "non_employee_checks", "users", column: "created_by_id"
  add_foreign_key "organizations", "companies", column: "primary_company_id"
  add_foreign_key "pay_component_tax_rules", "companies", on_delete: :restrict
  add_foreign_key "pay_component_tax_rules", "users", column: "approved_by_id", on_delete: :nullify
  add_foreign_key "pay_period_correction_events", "companies", on_delete: :restrict
  add_foreign_key "pay_period_correction_events", "pay_periods", column: "resulting_pay_period_id", on_delete: :nullify
  add_foreign_key "pay_period_correction_events", "pay_periods", on_delete: :restrict
  add_foreign_key "pay_period_correction_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "pay_period_excluded_employees", "employees"
  add_foreign_key "pay_period_excluded_employees", "pay_periods"
  add_foreign_key "pay_period_excluded_employees", "users", column: "excluded_by_id"
  add_foreign_key "pay_periods", "companies"
  add_foreign_key "pay_periods", "company_pay_schedules"
  add_foreign_key "pay_periods", "company_workweeks"
  add_foreign_key "pay_periods", "pay_periods", column: "corrects_pay_period_id"
  add_foreign_key "pay_periods", "pay_periods", column: "source_pay_period_id", on_delete: :nullify
  add_foreign_key "pay_periods", "pay_periods", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "pay_periods", "payroll_intake_sessions", column: "intake_stale_session_id", on_delete: :nullify
  add_foreign_key "pay_periods", "users", column: "voided_by_id", on_delete: :nullify
  add_foreign_key "payroll_field_definitions", "companies"
  add_foreign_key "payroll_filing_responsibilities", "companies"
  add_foreign_key "payroll_filing_responsibilities", "users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "payroll_go_live_reviews", "companies", column: "source_company_id", on_delete: :restrict
  add_foreign_key "payroll_go_live_reviews", "companies", on_delete: :restrict
  add_foreign_key "payroll_go_live_reviews", "historical_import_batches", on_delete: :restrict
  add_foreign_key "payroll_go_live_reviews", "users", column: "company_setup_reviewed_by_id", on_delete: :nullify
  add_foreign_key "payroll_go_live_reviews", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "payroll_go_live_reviews", "users", column: "operations_signed_by_id", on_delete: :nullify
  add_foreign_key "payroll_go_live_reviews", "users", column: "setup_applied_by_id", on_delete: :nullify
  add_foreign_key "payroll_go_live_reviews", "users", column: "technical_signed_by_id", on_delete: :nullify
  add_foreign_key "payroll_imports", "pay_periods"
  add_foreign_key "payroll_imports", "payroll_intake_sessions", on_delete: :restrict
  add_foreign_key "payroll_intake_documents", "payroll_intake_sessions"
  add_foreign_key "payroll_intake_rows", "employees"
  add_foreign_key "payroll_intake_rows", "pay_periods", column: "target_pay_period_id", on_delete: :restrict
  add_foreign_key "payroll_intake_rows", "payroll_intake_sessions"
  add_foreign_key "payroll_intake_rows", "payroll_items", column: "applied_payroll_item_id", on_delete: :nullify
  add_foreign_key "payroll_intake_rows", "users", column: "dispositioned_by_id", on_delete: :nullify
  add_foreign_key "payroll_intake_sessions", "companies"
  add_foreign_key "payroll_intake_sessions", "pay_periods"
  add_foreign_key "payroll_intake_sessions", "payroll_intake_sessions", column: "supersedes_id", on_delete: :restrict
  add_foreign_key "payroll_intake_sessions", "users", column: "applied_by_id", on_delete: :nullify
  add_foreign_key "payroll_intake_sessions", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "payroll_intake_sessions", "users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "payroll_intake_sessions", "users", column: "superseded_by_user_id", on_delete: :nullify
  add_foreign_key "payroll_item_deductions", "deduction_types"
  add_foreign_key "payroll_item_deductions", "payroll_items"
  add_foreign_key "payroll_item_earnings", "payroll_items"
  add_foreign_key "payroll_item_field_entries", "payroll_field_definitions"
  add_foreign_key "payroll_item_field_entries", "payroll_items"
  add_foreign_key "payroll_items", "annual_tax_configs", on_delete: :restrict
  add_foreign_key "payroll_items", "companies", on_delete: :restrict
  add_foreign_key "payroll_items", "employees"
  add_foreign_key "payroll_items", "pay_periods"
  add_foreign_key "payroll_items", "payroll_items", column: "correction_for_payroll_item_id"
  add_foreign_key "payroll_items", "users", column: "voided_by_user_id", on_delete: :nullify
  add_foreign_key "payroll_liability_allocations", "companies", on_delete: :restrict
  add_foreign_key "payroll_liability_allocations", "payroll_liability_entries", on_delete: :restrict
  add_foreign_key "payroll_liability_allocations", "payroll_liability_payments", on_delete: :restrict
  add_foreign_key "payroll_liability_due_dates", "companies", on_delete: :restrict
  add_foreign_key "payroll_liability_due_dates", "pay_periods", on_delete: :restrict
  add_foreign_key "payroll_liability_due_dates", "users", column: "updated_by_id", on_delete: :nullify
  add_foreign_key "payroll_liability_entries", "companies", on_delete: :restrict
  add_foreign_key "payroll_liability_entries", "pay_component_tax_rules", on_delete: :restrict
  add_foreign_key "payroll_liability_entries", "payroll_items", on_delete: :restrict
  add_foreign_key "payroll_liability_entries", "payroll_liability_postings", on_delete: :restrict
  add_foreign_key "payroll_liability_evidences", "companies", on_delete: :restrict
  add_foreign_key "payroll_liability_evidences", "payroll_liability_payments", on_delete: :restrict
  add_foreign_key "payroll_liability_evidences", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "payroll_liability_payments", "companies", on_delete: :restrict
  add_foreign_key "payroll_liability_payments", "pay_periods", on_delete: :restrict
  add_foreign_key "payroll_liability_payments", "payroll_liability_payments", column: "source_payment_id", on_delete: :restrict
  add_foreign_key "payroll_liability_payments", "users", column: "recorded_by_id", on_delete: :nullify
  add_foreign_key "payroll_liability_postings", "companies", on_delete: :restrict
  add_foreign_key "payroll_liability_postings", "pay_periods", on_delete: :restrict
  add_foreign_key "payroll_liability_postings", "payroll_liability_postings", column: "source_posting_id", on_delete: :restrict
  add_foreign_key "payroll_liability_postings", "users", column: "posted_by_id", on_delete: :nullify
  add_foreign_key "payroll_parallel_run_reviews", "companies", on_delete: :restrict
  add_foreign_key "payroll_parallel_run_reviews", "pay_periods", on_delete: :restrict
  add_foreign_key "payroll_parallel_run_reviews", "payroll_go_live_reviews", on_delete: :restrict
  add_foreign_key "payroll_parallel_run_reviews", "users", column: "recorded_by_id", on_delete: :nullify
  add_foreign_key "payroll_reminder_configs", "companies"
  add_foreign_key "payroll_reminder_logs", "companies"
  add_foreign_key "payroll_reminder_logs", "pay_periods"
  add_foreign_key "payroll_review_packages", "companies", on_delete: :restrict
  add_foreign_key "payroll_review_packages", "pay_periods", on_delete: :restrict
  add_foreign_key "payroll_review_packages", "users", column: "approval_recorded_by_id", on_delete: :nullify
  add_foreign_key "payroll_review_packages", "users", column: "approved_by_id", on_delete: :nullify
  add_foreign_key "payroll_review_packages", "users", column: "generated_by_id", on_delete: :nullify
  add_foreign_key "payroll_time_allocations", "companies"
  add_foreign_key "payroll_time_allocations", "daily_time_records"
  add_foreign_key "payroll_time_allocations", "employees"
  add_foreign_key "payroll_time_allocations", "payroll_items"
  add_foreign_key "printer_profiles", "organizations"
  add_foreign_key "punch_entries", "timecards"
  add_foreign_key "quarterly_compliance_packets", "companies"
  add_foreign_key "quarterly_compliance_packets", "users", column: "assigned_to_id"
  add_foreign_key "quarterly_compliance_packets", "users", column: "reviewed_by_id"
  add_foreign_key "quarterly_compliance_tasks", "quarterly_compliance_packets"
  add_foreign_key "quarterly_compliance_tasks", "users", column: "assigned_to_id"
  add_foreign_key "quarterly_compliance_tasks", "users", column: "reviewed_by_id"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "tax_brackets", "filing_status_configs"
  add_foreign_key "tax_config_audit_logs", "annual_tax_configs"
  add_foreign_key "time_tracking_employee_mappings", "companies"
  add_foreign_key "time_tracking_employee_mappings", "employees"
  add_foreign_key "time_tracking_employee_mappings", "time_tracking_sources"
  add_foreign_key "time_tracking_entry_allocations", "companies"
  add_foreign_key "time_tracking_entry_allocations", "employees"
  add_foreign_key "time_tracking_entry_allocations", "pay_periods"
  add_foreign_key "time_tracking_entry_allocations", "payroll_items"
  add_foreign_key "time_tracking_entry_allocations", "time_tracking_imports"
  add_foreign_key "time_tracking_entry_allocations", "time_tracking_sources"
  add_foreign_key "time_tracking_imports", "pay_periods"
  add_foreign_key "time_tracking_imports", "time_tracking_sources"
  add_foreign_key "time_tracking_imports", "users", column: "applied_by_id"
  add_foreign_key "time_tracking_imports", "users", column: "reconciled_by_id"
  add_foreign_key "time_tracking_sources", "companies"
  add_foreign_key "timecards", "companies"
  add_foreign_key "timecards", "employees", column: "applied_employee_id"
  add_foreign_key "timecards", "pay_periods"
  add_foreign_key "timecards", "payroll_items", column: "applied_payroll_item_id"
  add_foreign_key "transmittals", "companies"
  add_foreign_key "transmittals", "pay_periods"
  add_foreign_key "transmittals", "users", column: "created_by_id"
  add_foreign_key "transmittals", "users", column: "updated_by_id"
  add_foreign_key "user_invitations", "companies"
  add_foreign_key "user_invitations", "users", column: "invited_by_id"
  add_foreign_key "user_sessions", "users"
  add_foreign_key "users", "companies"
  add_foreign_key "users", "organizations"
  add_foreign_key "users", "users", column: "invited_by_id", on_delete: :nullify
  add_foreign_key "w2_filing_readinesses", "companies"
  add_foreign_key "w2_filing_readinesses", "users", column: "marked_ready_by_id"
  add_foreign_key "loan_transactions", "loan_transactions", column: "reverses_transaction_id"
  add_foreign_key "payroll_item_deductions", "employee_loans"
end
