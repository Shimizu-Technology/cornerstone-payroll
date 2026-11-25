# frozen_string_literal: true

module Api
  module V1
    class ViewAsGrantsController < ApplicationController
      include RecentVerification

      skip_before_action :track_authenticated_user_activity
      before_action :no_store
      before_action :require_support_company!, only: %i[targets create]
      before_action :require_recent_verification!, only: :create

      def targets
        search = params[:q].to_s.strip.first(100)
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
        TenantScope.with_company(@support_company.id) do
          clients = User.where(role: :client, organization_id: @support_company.organization_id, active: true)
            .where("name ILIKE ?", pattern).order(:name, :id).filter_map do |user|
              grant = ViewAsGrant.new(company: @support_company, target_user: user)
              target_payload(user, user.name) if grant.client_target
            end
          employees = []
          if employee_site_enabled?
            employees = Employee.where(company_id: @support_company.id)
              .where("concat_ws(' ', first_name, last_name) ILIKE ?", pattern)
              .order(:last_name, :first_name, :id).limit(30).map { |employee| target_payload(employee, employee.display_name) }
          end
          render json: { clients: clients.first(30), employees: employees, employee_site_enabled: employee_site_enabled? }
        end
      end

      def create
        reason = params[:reason].is_a?(String) ? params[:reason].strip : ""
        return render json: { error: "Enter a reason of 1 to 500 characters." }, status: :unprocessable_entity unless (1..500).cover?(reason.length)

        target = grant_target_attributes
        return view_as_unavailable unless target

        token = SecureRandom.urlsafe_base64(32)
        now = Time.current
        grant = ViewAsGrant.new(**target, staff_user: Current.real_user, company: @support_company, reason: reason,
          created_at: now, expires_at: now + ViewAsGrant::LIFETIME, token_digest: Digest::SHA256.hexdigest(token))

        TenantScope.with_company(grant.company_id) do
          name = if grant.employee_view?
            grant.employee_context&.employee&.display_name
          else
            grant.client_target&.name
          end
          return view_as_unavailable unless name.present?

          ViewAsGrant.transaction do
            grant.save!
            grant.record_access!(ViewAsGrant::STARTED_ACTION, name)
          end
          render json: grant_payload(grant, name).merge(token: token), status: :created
        end
      end

      def show
        grant = Current.view_as_grant
        return view_as_unavailable unless grant

        name = grant.employee_view? ? @view_as_employee_context.employee.display_name : current_user.name
        payload = grant_payload(grant, name)
        if grant.employee_view?
          payload[:link] = {
            id: @view_as_employee_context.employee_id.to_s, company_name: grant.company.name,
            subdomain_slug: grant.company.subdomain_slug, status: @view_as_employee_context.status,
            former_access_until: @view_as_employee_context.former_access_until&.iso8601
          }
        end
        render json: payload
      end

      def destroy
        grant = Current.view_as_grant
        return view_as_unavailable unless grant

        TenantScope.with_company(grant.company_id) do
          grant.with_lock do
            if grant.ended_at.nil?
              grant.update!(ended_at: Time.current)
              grant.record_access!("view_as#ended", nil)
            end
          end
        end
        head :no_content
      end

      private

      def no_store
        response.headers["Cache-Control"] = "private, no-store"
      end

      def require_support_company!
        return head :forbidden unless @clerk_token_payload && !@clerk_token_payload.key?("act") &&
          ViewAsGrant.allowed_staff?(Current.real_user)

        id = parsed_id(request.headers["X-Company-Id"])
        @support_company = Company.find_by(id: id)
        view_as_unavailable unless ViewAsGrant.allowed_company?(Current.real_user, @support_company)
      end

      def grant_target_attributes
        id = parsed_id(params[:target_id])
        return unless id

        case params[:target_type]
        when "client" then { target_user_id: id }
        when "employee" then { target_employee_id: id }
        end
      end

      def parsed_id(value)
        string = value.to_s
        return unless string.match?(/\A[1-9]\d{0,18}\z/) && string.to_i <= 2**63 - 1

        string.to_i
      end

      def employee_site_enabled?
        features = CompanyFeatures.for(@support_company)
        features.employee_portal_enabled? && features.subdomain_enabled? &&
          TenantSubdomainRegistry::SLUG_PATTERN.match?(@support_company.subdomain_slug.to_s)
      end

      def target_payload(target, name)
        { id: target.id.to_s, name: name }
      end

      def grant_payload(grant, name)
        {
          name: name, company_id: grant.company_id, expires_at: grant.expires_at.iso8601,
          employee_url: (grant.employee_origin if grant.employee_view?)
        }
      end

      def allow_client_subdomain_token?
        %w[show destroy].include?(action_name)
      end
    end
  end
end
