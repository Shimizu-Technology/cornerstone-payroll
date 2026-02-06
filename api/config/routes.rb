Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # API v1 routes
  namespace :api do
    namespace :v1 do
      # Authentication
      get "auth/login", to: "auth#login"
      get "auth/callback", to: "auth#callback"
      post "auth/logout", to: "auth#logout"
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
          end

          resources :payroll_items, only: [ :index, :show, :create, :update, :destroy ] do
            member do
              post :recalculate
            end
          end
        end

        # Reports
        get "reports/dashboard", to: "reports#dashboard"
        get "reports/payroll_register", to: "reports#payroll_register"
        get "reports/employee_pay_history", to: "reports#employee_pay_history"
        get "reports/tax_summary", to: "reports#tax_summary"
        get "reports/ytd_summary", to: "reports#ytd_summary"

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
