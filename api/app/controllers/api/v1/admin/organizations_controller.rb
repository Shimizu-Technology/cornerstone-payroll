# frozen_string_literal: true

module Api
  module V1
    module Admin
      class OrganizationsController < BaseController
        skip_before_action :enforce_company_access!
        before_action :require_super_admin!
        before_action :set_organization, only: [ :show, :update, :create_admin_user ]

        # GET /api/v1/admin/organizations
        def index
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, 50).to_i.clamp(1, 100)
          total_count = Organization.count
          organizations = Organization
            .includes(:companies, :primary_company)
            .order(:name)
            .offset((page - 1) * per_page)
            .limit(per_page)

          render json: {
            data: serialize_organizations(organizations),
            meta: {
              page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count.to_f / per_page).ceil
            }
          }
        end

        # GET /api/v1/admin/organizations/:id
        def show
          render json: { data: organization_json(@organization, detailed: true) }
        end

        # POST /api/v1/admin/organizations
        def create
          permitted = create_params
          admin_attrs = permitted.delete(:admin)
          primary_company_name = permitted.delete(:primary_company_name).presence || permitted[:name]

          organization = nil
          primary_company = nil
          admin_user = nil
          ActiveRecord::Base.transaction do
            organization = Organization.create!(permitted)
            primary_company = build_primary_company!(organization, primary_company_name)
            organization.update!(primary_company: primary_company)
            admin_user = build_org_admin!(organization, primary_company, admin_attrs) if admin_attrs.present?
          end

          invitation_result = admin_user ? invite_user(admin_user) : { success: false, error: nil }

          render json: {
            data: organization_json(organization.reload, detailed: true),
            admin_user: admin_user && user_json(admin_user),
            invitation_sent: invitation_result[:success] && invitation_result[:url].present?,
            invitation_error: invitation_result[:success] ? nil : invitation_result[:error]
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: [ "Organization slug is already taken" ] }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/organizations/:id
        def update
          if @organization.update(update_params)
            render json: { data: organization_json(@organization.reload, detailed: true) }
          else
            render json: { error: @organization.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/organizations/:id/admin_users
        def create_admin_user
          primary_company = @organization.primary_company
          unless primary_company
            return render json: { error: "Organization must have a primary company before admins can be invited" }, status: :unprocessable_entity
          end

          admin_user = build_org_admin!(@organization, primary_company, admin_user_params)
          invitation_result = invite_user(admin_user)

          render json: {
            data: user_json(admin_user),
            invitation_sent: invitation_result[:success] && invitation_result[:url].present?,
            invitation_error: invitation_result[:success] ? nil : invitation_result[:error]
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def set_organization
          @organization = Organization.find_by(id: params[:id])
          return if @organization

          render json: { error: "Organization not found" }, status: :not_found
        end

        def create_params
          permitted = params.require(:organization).permit(
            :name,
            :slug,
            :status,
            :client_limit,
            :unlimited_clients,
            :primary_company_name,
            admin: [ :email, :name ]
          )
          if ActiveModel::Type::Boolean.new.cast(permitted.delete(:unlimited_clients))
            permitted[:client_limit] = nil
          end
          permitted
        end

        def update_params
          permitted = params.require(:organization).permit(:name, :slug, :status, :client_limit, :unlimited_clients)
          if ActiveModel::Type::Boolean.new.cast(permitted.delete(:unlimited_clients))
            permitted[:client_limit] = nil
          end
          permitted
        end

        def admin_user_params
          params.require(:user).permit(:email, :name)
        end

        def build_primary_company!(organization, name)
          Company.create!(
            organization: organization,
            name: name,
            pay_frequency: "biweekly",
            check_stock_type: "top_check",
            check_offset_x: 0.0,
            check_offset_y: 0.0,
            next_check_number: 1001
          )
        end

        def build_org_admin!(organization, company, attrs)
          email = attrs[:email].to_s.strip.downcase
          user = User.new(
            organization: organization,
            company: company,
            email: email,
            name: attrs[:name].presence || email.split("@").first.titleize,
            role: "org_admin",
            active: true,
            clerk_id: "pending_#{SecureRandom.uuid}",
            invitation_status: "pending",
            invited_by: current_user,
            invited_at: Time.current
          )
          user.save!
          user
        end

        def invite_user(user)
          service = ClerkInvitationService.new
          unless service.configured?
            return { success: false, error: "Clerk API not configured" }
          end

          result = service.create_invitation(
            email: user.email,
            redirect_url: build_redirect_url,
            public_metadata: { role: user.role, organization_id: user.organization_id },
            ignore_existing: false
          )

          if result[:success]
            user.update!(clerk_invitation_id: result[:invitation_id])
            SendUserInviteEmailJob.perform_later(user.id, current_user&.id, result[:url]) if result[:url].present?
          end

          result
        end

        def build_redirect_url
          frontend = ENV.fetch("FRONTEND_URL") { ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").first.strip }
          "#{frontend}/login"
        end

        def organization_json(organization, detailed: false)
          snapshot = organization_serializer_snapshot
          companies = organization.companies.sort_by(&:name)
          admins = snapshot[:admins_by_org_id].fetch(organization.id, [])

          payload = {
            id: organization.id,
            name: organization.name,
            slug: organization.slug,
            status: organization.status,
            active: organization.status == "active",
            client_limit: organization.client_limit,
            clients_limit: organization.client_limit,
            unlimited_clients: organization.unlimited_clients?,
            primary_company_id: organization.primary_company_id,
            companies_count: companies.size,
            active_companies_count: companies.count(&:active),
            users_count: snapshot[:users_count_by_org_id].fetch(organization.id, 0),
            org_admins: admins.map { |user| user_json(user) },
            created_at: organization.created_at,
            updated_at: organization.updated_at
          }

          if detailed
            payload[:companies] = companies.map do |company|
              {
                id: company.id,
                name: company.name,
                active: company.active,
                pay_frequency: company.pay_frequency
              }
            end
          end

          payload
        end

        def serialize_organizations(organizations, detailed: false)
          organization_ids = organizations.map(&:id)
          @organization_serializer_snapshot = {
            users_count_by_org_id: User.where(organization_id: organization_ids).group(:organization_id).count,
            admins_by_org_id: User
              .where(organization_id: organization_ids, role: User.roles.values_at("admin", "org_admin").compact)
              .order(:name)
              .group_by(&:organization_id)
          }
          organizations.map { |organization| organization_json(organization, detailed: detailed) }
        ensure
          @organization_serializer_snapshot = nil
        end

        def organization_serializer_snapshot
          @organization_serializer_snapshot ||= {
            users_count_by_org_id: User.where(organization_id: @organization&.id).group(:organization_id).count,
            admins_by_org_id: User
              .where(organization_id: @organization&.id, role: User.roles.values_at("admin", "org_admin").compact)
              .order(:name)
              .group_by(&:organization_id)
          }
        end

        def user_json(user)
          {
            id: user.id,
            email: user.email,
            name: user.name,
            role: user.role,
            organization_id: user.organization_id,
            company_id: user.company_id,
            active: user.active,
            invitation_status: user.invitation_status,
            invitation_pending: user.invitation_pending?,
            invited_at: user.invited_at,
            last_login_at: user.last_login_at,
            created_at: user.created_at,
            updated_at: user.updated_at
          }
        end
      end
    end
  end
end
