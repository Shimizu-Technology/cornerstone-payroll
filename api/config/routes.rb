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
        resources :users, only: [ :index, :show, :create, :update ] do
          member do
            post :activate
            post :deactivate
          end
        end
        resources :audit_logs, only: [ :index ]
        resources :user_invitations, only: [ :create ]

        resources :employees, only: [ :index, :show, :create, :update, :destroy ]
        resources :departments, only: [ :index, :create, :update ]

        resources :pay_periods do
          member do
            post :run_payroll
            post :approve
            post :commit
            post :retry_tax_sync
            # CPR-71: Payroll correction workflow
            post :void
            post :create_correction_run
            get  :correction_history
            # Payroll import (MoSa Revel PDF + Excel)
            post :preview_import, to: "payroll_imports#preview"
            post :apply_import, to: "payroll_imports#apply"
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

        # CPR-66: Company check settings
        get   "companies/check_settings",    to: "checks#check_settings"
        patch "companies/check_settings",    to: "checks#update_check_settings"
        patch "companies/next_check_number", to: "checks#update_next_check_number"
        get   "companies/alignment_test_pdf", to: "checks#alignment_test_pdf"

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
        get "reports/w2_gu_preflight", to: "reports#w2_gu_preflight"
        get "reports/w2_gu_csv", to: "reports#w2_gu_csv"
        get "reports/w2_gu_pdf", to: "reports#w2_gu_pdf"

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
