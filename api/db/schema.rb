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

ActiveRecord::Schema[8.1].define(version: 2026_04_08_092809) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.bigint "company_id"
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "record_id"
    t.string "record_type"
    t.string "user_agent"
    t.bigint "user_id"
    t.index ["company_id"], name: "index_audit_logs_on_company_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["record_type", "record_id"], name: "index_audit_logs_on_record_type_and_record_id"
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
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

  create_table "companies", force: :cascade do |t|
    t.boolean "active", default: true
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
    t.datetime "created_at", null: false
    t.string "ein"
    t.string "email"
    t.string "name", null: false
    t.integer "next_check_number", default: 1001, null: false
    t.string "pay_frequency", default: "biweekly"
    t.string "phone"
    t.string "state"
    t.datetime "updated_at", null: false
    t.string "zip"
    t.index ["ein"], name: "index_companies_on_ein", unique: true
    t.index ["name"], name: "index_companies_on_name"
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
    t.string "sub_category"
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_deduction_types_on_category"
    t.index ["company_id", "name"], name: "index_deduction_types_on_company_id_and_name", unique: true
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

  create_table "employee_loans", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.decimal "current_balance", precision: 10, scale: 2, default: "0.0", null: false
    t.bigint "deduction_type_id"
    t.bigint "employee_id", null: false
    t.string "name", null: false
    t.text "notes"
    t.decimal "original_amount", precision: 10, scale: 2, null: false
    t.date "paid_off_date"
    t.decimal "payment_amount", precision: 10, scale: 2
    t.date "start_date"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status"], name: "index_employee_loans_on_company_id_and_status"
    t.index ["company_id"], name: "index_employee_loans_on_company_id"
    t.index ["deduction_type_id"], name: "index_employee_loans_on_deduction_type_id"
    t.index ["employee_id", "status"], name: "index_employee_loans_on_employee_id_and_status"
    t.index ["employee_id"], name: "index_employee_loans_on_employee_id"
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
    t.string "contractor_ein"
    t.string "contractor_pay_type", default: "flat_fee"
    t.string "contractor_type", default: "individual"
    t.datetime "created_at", null: false
    t.date "date_of_birth"
    t.bigint "department_id"
    t.string "email"
    t.decimal "employer_retirement_match_rate", precision: 5, scale: 4, default: "0.0"
    t.decimal "employer_roth_match_rate", precision: 5, scale: 4, default: "0.0"
    t.string "employment_type", default: "hourly", null: false
    t.string "filing_status", default: "single"
    t.string "first_name", null: false
    t.date "hire_date"
    t.string "last_name", null: false
    t.string "middle_name"
    t.string "pay_frequency", default: "biweekly"
    t.decimal "pay_rate", precision: 12, scale: 6, null: false
    t.string "phone"
    t.decimal "retirement_rate", precision: 5, scale: 4, default: "0.0"
    t.decimal "roth_retirement_rate", precision: 5, scale: 4, default: "0.0"
    t.string "salary_type", default: "annual", null: false
    t.string "ssn_encrypted"
    t.string "state"
    t.string "status", default: "active"
    t.date "termination_date"
    t.datetime "updated_at", null: false
    t.decimal "w4_dependent_credit", precision: 10, scale: 2, default: "0.0", null: false
    t.boolean "w4_step2_multiple_jobs", default: false, null: false
    t.decimal "w4_step4a_other_income", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "w4_step4b_deductions", precision: 10, scale: 2, default: "0.0", null: false
    t.boolean "w9_on_file", default: false, null: false
    t.string "zip"
    t.index ["company_id", "last_name", "first_name"], name: "index_employees_on_company_id_and_last_name_and_first_name"
    t.index ["company_id"], name: "index_employees_on_company_id"
    t.index ["department_id"], name: "index_employees_on_department_id"
    t.index ["employment_type"], name: "index_employees_on_employment_type"
    t.index ["status"], name: "index_employees_on_status"
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

  create_table "loan_transactions", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.decimal "balance_after", precision: 10, scale: 2, null: false
    t.decimal "balance_before", precision: 10, scale: 2, null: false
    t.datetime "created_at", null: false
    t.bigint "employee_loan_id", null: false
    t.text "notes"
    t.bigint "pay_period_id"
    t.bigint "payroll_item_id"
    t.date "transaction_date", null: false
    t.string "transaction_type", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_loan_id", "pay_period_id"], name: "idx_loan_txns_on_loan_and_pp"
    t.index ["employee_loan_id"], name: "index_loan_transactions_on_employee_loan_id"
    t.index ["pay_period_id"], name: "index_loan_transactions_on_pay_period_id"
    t.index ["payroll_item_id"], name: "index_loan_transactions_on_payroll_item_id"
    t.index ["transaction_type"], name: "index_loan_transactions_on_transaction_type"
  end

  create_table "non_employee_checks", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "check_number"
    t.string "check_type", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.text "description"
    t.string "memo"
    t.bigint "pay_period_id", null: false
    t.string "payable_to", null: false
    t.integer "print_count", default: 0, null: false
    t.datetime "printed_at"
    t.string "reference_number"
    t.datetime "updated_at", null: false
    t.string "void_reason"
    t.boolean "voided", default: false, null: false
    t.datetime "voided_at"
    t.index ["check_type"], name: "index_non_employee_checks_on_check_type"
    t.index ["company_id", "check_number"], name: "idx_ne_checks_on_company_check_num", unique: true, where: "(check_number IS NOT NULL)"
    t.index ["company_id"], name: "index_non_employee_checks_on_company_id"
    t.index ["created_by_id"], name: "index_non_employee_checks_on_created_by_id"
    t.index ["pay_period_id", "company_id"], name: "idx_unique_non_voided_fit_check_per_period", unique: true, where: "(((check_type)::text = 'tax_deposit'::text) AND ((payable_to)::text = 'EFTPS - Federal Income Tax'::text) AND (voided = false))"
    t.index ["pay_period_id"], name: "index_non_employee_checks_on_pay_period_id"
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

  create_table "pay_periods", force: :cascade do |t|
    t.bigint "approved_by_id"
    t.datetime "committed_at"
    t.bigint "company_id", null: false
    t.string "correction_status"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.date "end_date", null: false
    t.text "notes"
    t.date "pay_date", null: false
    t.bigint "source_pay_period_id"
    t.date "start_date", null: false
    t.string "status", default: "draft"
    t.bigint "superseded_by_id"
    t.integer "tax_sync_attempts", default: 0, null: false
    t.string "tax_sync_idempotency_key"
    t.text "tax_sync_last_error"
    t.string "tax_sync_status", default: "pending"
    t.datetime "tax_synced_at"
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.index ["company_id", "end_date"], name: "index_pay_periods_on_company_id_and_end_date"
    t.index ["company_id", "start_date"], name: "index_pay_periods_on_company_id_and_start_date"
    t.index ["company_id", "status"], name: "index_pay_periods_on_company_id_and_status"
    t.index ["company_id"], name: "index_pay_periods_on_company_id"
    t.index ["correction_status"], name: "index_pay_periods_on_correction_status"
    t.index ["source_pay_period_id"], name: "idx_pay_periods_unique_source_correction_run", unique: true, where: "((source_pay_period_id IS NOT NULL) AND ((correction_status)::text <> 'voided'::text))"
    t.index ["status"], name: "index_pay_periods_on_status"
    t.index ["superseded_by_id"], name: "idx_pay_periods_unique_superseded_by", unique: true, where: "(superseded_by_id IS NOT NULL)"
    t.index ["tax_sync_idempotency_key"], name: "index_pay_periods_on_tax_sync_idempotency_key", unique: true
    t.index ["tax_sync_status"], name: "index_pay_periods_on_tax_sync_status"
    t.index ["voided_by_id"], name: "index_pay_periods_on_voided_by_id"
  end

  create_table "payroll_imports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "excel_filename"
    t.jsonb "matched_data", default: []
    t.bigint "pay_period_id", null: false
    t.string "pdf_filename"
    t.jsonb "raw_data", default: {}
    t.string "status", default: "pending", null: false
    t.jsonb "unmatched_pdf_names", default: []
    t.datetime "updated_at", null: false
    t.jsonb "validation_errors", default: []
    t.index ["pay_period_id", "status"], name: "index_payroll_imports_on_pay_period_id_and_status"
    t.index ["pay_period_id"], name: "index_payroll_imports_on_pay_period_id"
  end

  create_table "payroll_item_deductions", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.bigint "deduction_type_id", null: false
    t.string "label", null: false
    t.bigint "payroll_item_id", null: false
    t.datetime "updated_at", null: false
    t.index ["deduction_type_id"], name: "index_payroll_item_deductions_on_deduction_type_id"
    t.index ["payroll_item_id", "deduction_type_id"], name: "idx_pi_deductions_on_pi_and_dt", unique: true
    t.index ["payroll_item_id"], name: "index_payroll_item_deductions_on_payroll_item_id"
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

  create_table "payroll_items", force: :cascade do |t|
    t.decimal "additional_withholding", precision: 10, scale: 2, default: "0.0"
    t.decimal "bonus", precision: 10, scale: 2, default: "0.0"
    t.string "check_number"
    t.integer "check_print_count", default: 0, null: false
    t.datetime "check_printed_at"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "custom_columns_data", default: {}
    t.bigint "employee_id", null: false
    t.decimal "employer_medicare_tax", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "employer_retirement_match", precision: 10, scale: 2, default: "0.0"
    t.decimal "employer_roth_retirement_match", precision: 10, scale: 2, default: "0.0"
    t.decimal "employer_social_security_tax", precision: 10, scale: 2, default: "0.0", null: false
    t.string "employment_type", null: false
    t.decimal "gross_pay", precision: 12, scale: 2, default: "0.0"
    t.decimal "holiday_hours", precision: 8, scale: 2, default: "0.0"
    t.decimal "hours_worked", precision: 8, scale: 2, default: "0.0"
    t.string "import_source"
    t.decimal "insurance_payment", precision: 10, scale: 2, default: "0.0"
    t.decimal "loan_deduction", precision: 10, scale: 2, default: "0.0"
    t.decimal "loan_payment", precision: 10, scale: 2, default: "0.0"
    t.decimal "medicare_tax", precision: 10, scale: 2, default: "0.0"
    t.decimal "net_pay", precision: 12, scale: 2, default: "0.0"
    t.decimal "non_taxable_pay", precision: 12, scale: 2, default: "0.0"
    t.decimal "overtime_hours", precision: 8, scale: 2, default: "0.0"
    t.bigint "pay_period_id", null: false
    t.decimal "pay_rate", precision: 12, scale: 6, null: false
    t.decimal "pto_hours", precision: 8, scale: 2, default: "0.0"
    t.decimal "reported_tips", precision: 10, scale: 2, default: "0.0"
    t.string "reprint_of_check_number"
    t.decimal "retirement_payment", precision: 10, scale: 2, default: "0.0"
    t.decimal "roth_retirement_payment", precision: 10, scale: 2, default: "0.0"
    t.decimal "salary_override", precision: 12, scale: 2
    t.decimal "social_security_tax", precision: 10, scale: 2, default: "0.0"
    t.string "tip_pool"
    t.decimal "tips", precision: 10, scale: 2, default: "0.0"
    t.decimal "total_additions", precision: 12, scale: 2, default: "0.0"
    t.decimal "total_deductions", precision: 12, scale: 2, default: "0.0"
    t.datetime "updated_at", null: false
    t.string "void_reason"
    t.boolean "voided", default: false, null: false
    t.datetime "voided_at"
    t.bigint "voided_by_user_id"
    t.decimal "withholding_tax", precision: 10, scale: 2, default: "0.0"
    t.decimal "withholding_tax_override", precision: 10, scale: 2
    t.decimal "ytd_gross", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_medicare_tax", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_net", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_retirement", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_roth_retirement", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_social_security_tax", precision: 14, scale: 2, default: "0.0"
    t.decimal "ytd_withholding_tax", precision: 14, scale: 2, default: "0.0"
    t.index ["check_number"], name: "index_payroll_items_on_check_number"
    t.index ["company_id", "check_number"], name: "index_payroll_items_on_company_check_number_unique", unique: true, where: "(check_number IS NOT NULL)"
    t.index ["company_id"], name: "index_payroll_items_on_company_id"
    t.index ["employee_id"], name: "index_payroll_items_on_employee_id"
    t.index ["pay_period_id", "employee_id"], name: "index_payroll_items_on_pay_period_id_and_employee_id", unique: true
    t.index ["pay_period_id"], name: "index_payroll_items_on_pay_period_id"
    t.index ["reprint_of_check_number"], name: "index_payroll_items_on_reprint_of_check_number"
    t.index ["voided"], name: "index_payroll_items_on_voided"
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

  create_table "timecards", force: :cascade do |t|
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
    t.datetime "generated_at"
    t.jsonb "non_employee_check_numbers", default: {}
    t.jsonb "notes", default: []
    t.bigint "pay_period_id", null: false
    t.string "preparer_name"
    t.jsonb "report_list", default: []
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
    t.bigint "invited_by_id", null: false
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
    t.datetime "last_login_at"
    t.string "name", null: false
    t.integer "role", default: 0, null: false
    t.boolean "super_admin", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "workos_id"
    t.index ["clerk_id"], name: "index_users_on_clerk_id", unique: true
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["workos_id"], name: "index_users_on_workos_id", unique: true
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

  add_foreign_key "audit_logs", "companies"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "check_events", "payroll_items"
  add_foreign_key "check_events", "users", on_delete: :nullify
  add_foreign_key "company_assignments", "companies"
  add_foreign_key "company_assignments", "users"
  add_foreign_key "company_ytd_totals", "companies"
  add_foreign_key "deduction_types", "companies"
  add_foreign_key "department_ytd_totals", "departments"
  add_foreign_key "departments", "companies"
  add_foreign_key "employee_deductions", "deduction_types"
  add_foreign_key "employee_deductions", "employees"
  add_foreign_key "employee_loans", "companies"
  add_foreign_key "employee_loans", "deduction_types"
  add_foreign_key "employee_loans", "employees"
  add_foreign_key "employee_wage_rates", "employees"
  add_foreign_key "employee_ytd_totals", "employees"
  add_foreign_key "employees", "companies"
  add_foreign_key "employees", "departments"
  add_foreign_key "filing_status_configs", "annual_tax_configs"
  add_foreign_key "loan_transactions", "employee_loans"
  add_foreign_key "loan_transactions", "pay_periods"
  add_foreign_key "loan_transactions", "payroll_items"
  add_foreign_key "non_employee_checks", "companies"
  add_foreign_key "non_employee_checks", "pay_periods"
  add_foreign_key "non_employee_checks", "users", column: "created_by_id"
  add_foreign_key "pay_period_correction_events", "companies", on_delete: :restrict
  add_foreign_key "pay_period_correction_events", "pay_periods", column: "resulting_pay_period_id", on_delete: :nullify
  add_foreign_key "pay_period_correction_events", "pay_periods", on_delete: :restrict
  add_foreign_key "pay_period_correction_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "pay_periods", "companies"
  add_foreign_key "pay_periods", "pay_periods", column: "source_pay_period_id", on_delete: :nullify
  add_foreign_key "pay_periods", "pay_periods", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "pay_periods", "users", column: "voided_by_id", on_delete: :nullify
  add_foreign_key "payroll_imports", "pay_periods"
  add_foreign_key "payroll_item_deductions", "deduction_types"
  add_foreign_key "payroll_item_deductions", "payroll_items"
  add_foreign_key "payroll_item_earnings", "payroll_items"
  add_foreign_key "payroll_items", "companies", on_delete: :restrict
  add_foreign_key "payroll_items", "employees"
  add_foreign_key "payroll_items", "pay_periods"
  add_foreign_key "payroll_items", "users", column: "voided_by_user_id", on_delete: :nullify
  add_foreign_key "payroll_reminder_configs", "companies"
  add_foreign_key "payroll_reminder_logs", "companies"
  add_foreign_key "payroll_reminder_logs", "pay_periods"
  add_foreign_key "punch_entries", "timecards"
  add_foreign_key "tax_brackets", "filing_status_configs"
  add_foreign_key "tax_config_audit_logs", "annual_tax_configs"
  add_foreign_key "timecards", "companies"
  add_foreign_key "timecards", "pay_periods"
  add_foreign_key "transmittals", "companies"
  add_foreign_key "transmittals", "pay_periods"
  add_foreign_key "transmittals", "users", column: "created_by_id"
  add_foreign_key "transmittals", "users", column: "updated_by_id"
  add_foreign_key "user_invitations", "companies"
  add_foreign_key "user_invitations", "users", column: "invited_by_id"
  add_foreign_key "user_sessions", "users"
  add_foreign_key "users", "companies"
  add_foreign_key "users", "users", column: "invited_by_id", on_delete: :nullify
  add_foreign_key "w2_filing_readinesses", "companies"
  add_foreign_key "w2_filing_readinesses", "users", column: "marked_ready_by_id"
end
