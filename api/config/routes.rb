Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # API v1 routes
  namespace :api do
    namespace :v1 do
      # Auth - current user info (Clerk JWT verified in ApplicationController)
      get "auth/me", to: "auth#me"

      namespace :admin do
        # CPR-66: Company check settings
        # These must appear before `resources :companies` so paths like
        # `/admin/companies/check_settings` do not get swallowed by `:id`.
        get   "companies/check_settings",     to: "checks#check_settings"
        patch "companies/check_settings",     to: "checks#update_check_settings"
        patch "companies/next_check_number",  to: "checks#update_next_check_number"
        get   "companies/alignment_test_pdf", to: "checks#alignment_test_pdf"

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
            post :retry_tax_sync
            # CPR-71: Payroll correction workflow
            post :void
            post :create_correction_run
            get  :correction_history
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
        post "payroll_items/:payroll_item_id/void",              to: "checks#void",           as: :payroll_item_void
        post "payroll_items/:payroll_item_id/reprint",           to: "checks#reprint",        as: :payroll_item_reprint

        # Reports
        get "reports/dashboard", to: "reports#dashboard"
        get "reports/payroll_register", to: "reports#payroll_register"
        get "reports/payroll_register_csv", to: "reports#payroll_register_csv"
        get "reports/payroll_register_pdf", to: "reports#payroll_register_pdf"
        get "reports/employee_pay_history", to: "reports#employee_pay_history"
        get "reports/tax_summary", to: "reports#tax_summary"
        get "reports/tax_summary_csv", to: "reports#tax_summary_csv"
        get "reports/tax_summary_pdf", to: "reports#tax_summary_pdf"
        get "reports/ytd_summary", to: "reports#ytd_summary"
        get "reports/form_941_gu", to: "reports#form_941_gu"
        get "reports/w2_gu", to: "reports#w2_gu"
        post "reports/w2_gu_preflight", to: "reports#w2_gu_preflight"
        get "reports/w2_gu_filing_readiness", to: "reports#w2_gu_filing_readiness"
        post "reports/w2_gu_mark_ready", to: "reports#w2_gu_mark_ready"
        get "reports/w2_gu_csv", to: "reports#w2_gu_csv"
        get "reports/w2_gu_pdf", to: "reports#w2_gu_pdf"
        get "reports/form_1099_nec", to: "reports#form_1099_nec"
        get "reports/form_1099_nec_pdf", to: "reports#form_1099_nec_pdf"

        # New payroll parity reports
        get "reports/payroll_summary_by_employee_pdf", to: "reports#payroll_summary_by_employee_pdf"
        get "reports/deductions_contributions_pdf", to: "reports#deductions_contributions_pdf"
        get "reports/paycheck_history_pdf", to: "reports#paycheck_history_pdf"
        get "reports/retirement_plans_pdf", to: "reports#retirement_plans_pdf"
        get "reports/installment_loans_pdf", to: "reports#installment_loans_pdf"
        get "reports/transmittal_preview", to: "reports#transmittal_preview"
        match "reports/transmittal_log_pdf", to: "reports#transmittal_log_pdf", via: [:get, :post]
        match "reports/full_print_package_pdf", to: "reports#full_print_package_pdf", via: [:get, :post]

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
        resources :punch_entries, only: [:update]

        # Employee Wage Rates
        resources :employee_wage_rates, only: [:index, :create, :update, :destroy]

        # Pay Stubs
        get "pay_stubs/:id", to: "pay_stubs#show"
        post "pay_stubs/:id/generate", to: "pay_stubs#generate"
        get "pay_stubs/:id/download", to: "pay_stubs#download"
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
