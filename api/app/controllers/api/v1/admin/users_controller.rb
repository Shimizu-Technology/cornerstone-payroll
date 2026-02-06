# frozen_string_literal: true

module Api
  module V1
    module Admin
      class UsersController < BaseController
        before_action :require_admin!
        before_action :set_user, only: [ :show, :update, :activate, :deactivate ]

        # GET /api/v1/admin/users
        def index
          users = User.where(company_id: current_company_id).order(:name)
          if params[:search].present?
            query = "%#{params[:search]}%"
            users = users.where("name ILIKE ? OR email ILIKE ?", query, query)
          end

          render json: { data: users.map { |user| user_json(user) } }
        end

        # GET /api/v1/admin/users/:id
        def show
          render json: { data: user_json(@user) }
        end

        # POST /api/v1/admin/users
        def create
          user = User.new(user_params.merge(company_id: current_company_id))
          user.save!
          render json: { data: user_json(user) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/users/:id
        def update
          if @user.id == current_user_id && user_params[:role].present? && user_params[:role] != @user.role
            return render json: { error: "Cannot change your own role" }, status: :unprocessable_entity
          end

          # Prevent demoting the last admin
          if @user.role == "admin" && user_params[:role].present? && user_params[:role] != "admin"
            if User.where(company_id: current_company_id, role: "admin", active: true).where.not(id: @user.id).none?
              return render json: { error: "Cannot demote the last active admin" }, status: :unprocessable_entity
            end
          end

          @user.update!(user_params)
          render json: { data: user_json(@user) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users/:id/activate
        def activate
          @user.update!(active: true)
          render json: { data: user_json(@user) }
        end

        # POST /api/v1/admin/users/:id/deactivate
        def deactivate
          if @user.id == current_user_id
            return render json: { error: "Cannot deactivate your own account" }, status: :unprocessable_entity
          end

          # Prevent deactivating the last active admin
          if @user.role == "admin"
            if User.where(company_id: current_company_id, role: "admin", active: true).where.not(id: @user.id).none?
              return render json: { error: "Cannot deactivate the last active admin" }, status: :unprocessable_entity
            end
          end

          @user.update!(active: false)
          render json: { data: user_json(@user) }
        end

        private

        def set_user
          @user = User.find_by(id: params[:id], company_id: current_company_id)
          return if @user

          render json: { error: "User not found" }, status: :not_found
        end

        def user_params
          params.require(:user).permit(:email, :name, :role, :active)
        end

        def user_json(user)
          {
            id: user.id,
            email: user.email,
            name: user.name,
            role: user.role,
            company_id: user.company_id,
            active: user.active,
            last_login_at: user.last_login_at,
            created_at: user.created_at,
            updated_at: user.updated_at
          }
        end
      end
    end
  end
end
