Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # API v1 routes
  namespace :api do
    namespace :v1 do
      # Auth - current user info (Clerk JWT verified in ApplicationController)
      get "auth/me", to: "auth#me"
      post "cable_ticket", to: "cable_tickets#create"
      get "companies", to: "companies#index"

      resources :form_500s, only: [] do
        collection do
          get :defaults
          post :save
          post :preview
          post :download
        end
      end

      namespace :client do
        resources :employees, only: [ :index, :show, :create, :update ]
        resources :departments, only: [ :index, :create, :update ]
        resources :documents, only: [ :index, :create, :destroy ] do
          member do
            get :download
            get :preview
          end
        end
        resources :portal_threads, only: [ :index, :show, :create, :update ] do
          member do
            post :mark_read
          end
          resources :messages, only: [ :create ], controller: :portal_messages
        end
        resources :employee_change_requests, only: [ :index, :show ]
        resources :pay_periods, only: [ :index, :show ]

        namespace :reports do
          get :dashboard
          get :payroll_register
          get :payroll_register_pdf
          get :ytd_summary
        end
      end

      namespace :admin do
        # CPR-66: Company check settings
        # These must appear before `resources :companies` so paths like
        # `/admin/companies/check_settings` do not get swallowed by `:id`.
        get   "companies/check_settings",     to: "checks#check_settings"
        patch "companies/check_settings",     to: "checks#update_check_settings"
        patch "companies/next_check_number",  to: "checks#update_next_check_number"
        get   "companies/alignment_test_pdf", to: "checks#alignment_test_pdf"

        # Printer Profiles (saved check alignment presets per printer)
        resources :printer_profiles, only: [:index, :show, :create, :update, :destroy] do
          member do
            post :apply
          end
        end

        resources :companies, only: [:index, :show, :create, :update]
        resources :company_assignments, only: [:index, :create, :destroy] do
          collection do
            put :bulk_update
          end
        end
        resources :users, only: [ :index, :show, :create, :update, :destroy ] do
          member do
            post :activate
            post :deactivate
            post :resend_invitation
          end
        end
        resources :audit_logs, only: [ :index ]
        resources :employee_change_requests, only: [ :index, :show ] do
          member do
            patch :approve
            patch :reject
          end
        end
        resources :client_documents, only: [ :index, :create, :destroy ] do
          member do
            get :download
            get :preview
          end
        end
        resources :portal_threads, only: [ :index, :show, :create, :update ] do
          member do
            post :mark_read
          end
          resources :messages, only: [ :create ], controller: :portal_messages
        end
        resources :user_invitations, only: [ :create ]

        resources :employees, only: [ :index, :show, :create, :update, :destroy ] do
          member do
            post :reactivate
          end
        end

        # Employee Bulk Import
        get  "employee_bulk_imports/template", to: "employee_bulk_imports#template"
        post "employee_bulk_imports/preview",  to: "employee_bulk_imports#preview"
        post "employee_bulk_imports/apply_json", to: "employee_bulk_imports#apply_json"
        resources :departments, only: [ :index, :create, :update ]

        resources :pay_periods do
          member do
            post :run_payroll
            post :approve
            post :unapprove
            post :commit
            post :generate_fit_check
            post :retry_tax_sync
            # CPR-71: Payroll correction workflow
            post :void
            post :create_correction_run
            get  :correction_history
            # Per-employee corrective paycheck (off-cycle supplemental period)
            post :corrective_paycheck_preview
            post :corrective_paychecks
            get  :supplemental_pay_periods
            # Payroll import (MoSa Revel PDF + Excel)
            post :preview_import, to: "payroll_imports#preview"
            post :apply_import, to: "payroll_imports#apply"
            # Timecard OCR CSV import
            post :preview_timecard_import, to: "timecard_imports#preview"
            post :apply_timecard_import, to: "timecard_imports#apply"
          end

          resources :payroll_items, only: [ :index, :show, :create, :update, :destroy ] do
            member do
              post :recalculate
            end
          end

          # CPR-66: Check printing (pay-period scoped)
          get  "checks",                    to: "checks#index"
          post "checks/batch_pdf",          to: "checks#batch_pdf"
          post "checks/mark_all_printed",   to: "checks#mark_all_printed"
        end

        # CPR-66: Per-item check actions (payroll_item_id param)
        get  "payroll_items/:payroll_item_id/check",             to: "checks#show",           as: :payroll_item_check
        post "payroll_items/:payroll_item_id/check/mark_printed", to: "checks#mark_printed",  as: :payroll_item_check_mark_printed
        patch "payroll_items/:payroll_item_id/check_number",      to: "checks#update_check_number", as: :payroll_item_check_number
        post "payroll_items/:payroll_item_id/void",              to: "checks#void",           as: :payroll_item_void
        post "payroll_items/:payroll_item_id/reprint",           to: "checks#reprint",        as: :payroll_item_reprint
        # Replace (uncashed) — void + cut a corrected check on the same item.
        # Used when the original check is in your possession (never given out
        # or returned by the employee uncashed) and the financial values need
        # to change (otherwise use reprint).
        post "payroll_items/:payroll_item_id/replace_check_preview", to: "checks#replace_preview", as: :payroll_item_replace_check_preview
        post "payroll_items/:payroll_item_id/replace_check",         to: "checks#replace_check",   as: :payroll_item_replace_check

        # Reports
        get "reports/dashboard", to: "reports#dashboard"
        get "reports/payroll_register", to: "reports#payroll_register"
        get "reports/payroll_register_csv", to: "reports#payroll_register_csv"
        get "reports/payroll_register_pdf", to: "reports#payroll_register_pdf"
        get "reports/payroll_register_xlsx", to: "reports#payroll_register_xlsx"
        get "reports/employee_pay_history", to: "reports#employee_pay_history"
        get "reports/employee_pay_history_xlsx", to: "reports#employee_pay_history_xlsx"
        get "reports/tax_summary", to: "reports#tax_summary"
        get "reports/tax_summary_csv", to: "reports#tax_summary_csv"
        get "reports/tax_summary_pdf", to: "reports#tax_summary_pdf"
        get "reports/tax_summary_xlsx", to: "reports#tax_summary_xlsx"
        get "reports/ytd_summary", to: "reports#ytd_summary"
        get "reports/ytd_summary_xlsx", to: "reports#ytd_summary_xlsx"
        get "reports/form_941_gu", to: "reports#form_941_gu"
        get "reports/form_941_gu_xlsx", to: "reports#form_941_gu_xlsx"
        get "reports/w2_gu", to: "reports#w2_gu"
        post "reports/w2_gu_preflight", to: "reports#w2_gu_preflight"
        get "reports/w2_gu_filing_readiness", to: "reports#w2_gu_filing_readiness"
        post "reports/w2_gu_mark_ready", to: "reports#w2_gu_mark_ready"
        get "reports/w2_gu_csv", to: "reports#w2_gu_csv"
        get "reports/w2_gu_pdf", to: "reports#w2_gu_pdf"
        get "reports/w2_gu_xlsx", to: "reports#w2_gu_xlsx"
        get "reports/form_1099_nec", to: "reports#form_1099_nec"
        get "reports/form_1099_nec_pdf", to: "reports#form_1099_nec_pdf"
        get "reports/form_1099_nec_xlsx", to: "reports#form_1099_nec_xlsx"

        # New payroll parity reports
        get "reports/payroll_summary_by_employee_pdf", to: "reports#payroll_summary_by_employee_pdf"
        get "reports/payroll_summary_by_employee_xlsx", to: "reports#payroll_summary_by_employee_xlsx"
        get "reports/deductions_contributions_pdf", to: "reports#deductions_contributions_pdf"
        get "reports/deductions_contributions_xlsx", to: "reports#deductions_contributions_xlsx"
        get "reports/paycheck_history_pdf", to: "reports#paycheck_history_pdf"
        get "reports/paycheck_history_xlsx", to: "reports#paycheck_history_xlsx"
        get "reports/retirement_plans_pdf", to: "reports#retirement_plans_pdf"
        get "reports/retirement_plans_xlsx", to: "reports#retirement_plans_xlsx"
        get "reports/installment_loans_pdf", to: "reports#installment_loans_pdf"
        get "reports/installment_loans_xlsx", to: "reports#installment_loans_xlsx"
        get "reports/transmittal_preview", to: "reports#transmittal_preview"
        match "reports/transmittal_log_pdf", to: "reports#transmittal_log_pdf", via: [:get, :post]
        match "reports/full_print_package_pdf", to: "reports#full_print_package_pdf", via: [:get, :post]
        match "reports/check_signoff_sheet", to: "reports#check_signoff_sheet", via: [:get, :post]
        post "reports/check_signoff_pdf", to: "reports#check_signoff_pdf"
        get "reports/check_signoff_preview", to: "reports#check_signoff_preview"

        # Payroll Reminder Config (per-company, singleton)
        get   "payroll_reminder_config",      to: "payroll_reminder_configs#show"
        put   "payroll_reminder_config",      to: "payroll_reminder_configs#update"
        post  "payroll_reminder_config/test", to: "payroll_reminder_configs#test"
        get   "payroll_reminder_config/logs", to: "payroll_reminder_configs#logs"

        # Employee Loans
        resources :employee_loans do
          member do
            post :record_payment
            post :record_addition
          end
        end

        # Non-Employee Checks
        resources :non_employee_checks, except: [:new, :edit] do
          member do
            post :mark_printed
            post :void_check
            get :check_pdf
            get :history
          end
        end

        # Timecard OCR
        resources :timecards, only: [:index, :show, :create, :update, :destroy] do
          member do
            patch :review
            patch :reprocess
            post :apply_to_payroll
          end
        end
        resources :punch_entries, only: [:create, :update]

        # Employee Wage Rates
        resources :employee_wage_rates, only: [:index, :create, :update, :destroy]

        # Pay Stubs
        get "pay_stubs/:id", to: "pay_stubs#show"
        post "pay_stubs/:id/generate", to: "pay_stubs#generate"
        get "pay_stubs/:id/download", to: "pay_stubs#download"
        post "pay_stubs/batch_pdf", to: "pay_stubs#batch_pdf"
        post "pay_stubs/batch_generate", to: "pay_stubs#batch_generate"
        get "pay_stubs/employee/:employee_id", to: "pay_stubs#employee_stubs"

        # Tax Configuration Management
        resources :tax_configs, only: [ :index, :show, :create, :update, :destroy ] do
          member do
            post :activate
            get :audit_logs
          end
          collection do
            patch ":id/filing_status/:filing_status", to: "tax_configs#update_filing_status"
            patch ":id/brackets/:filing_status", to: "tax_configs#update_brackets"
          end
        end
      end
    end
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
