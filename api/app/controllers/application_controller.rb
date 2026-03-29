# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ClerkAuthenticatable

  private

  def auth_disabled?
    return false if Rails.env.production?

    ENV["AUTH_ENABLED"] != "true"
  end

  # Fallback user for development when auth is disabled
  def current_user
    return super unless auth_disabled?

    @current_user ||= User.find_by(role: "admin") || User.first
  end

  def current_company
    @current_company ||= Company.find_by(id: current_company_id)
  end

  def current_company_id
    @current_company_id ||= resolve_company_id
  end

  def current_user_id
    current_user&.id
  end

  def require_admin!
    unless current_user&.admin?
      render json: { error: "Admin access required" }, status: :forbidden
    end
  end

  def require_manager_or_admin!
    unless current_user&.admin? || current_user&.manager?
      render json: { error: "Manager or admin access required" }, status: :forbidden
    end
  end

  # Backward-compatible alias used by admin base controller.
  def require_admin_or_manager!
    require_manager_or_admin!
  end

  # Super admins can switch to any company via X-Company-Id header.
  # Accountants can switch to their assigned companies.
  # Regular users are always scoped to their own company.
  def resolve_company_id
    header_company_id = request.headers["X-Company-Id"].presence&.to_i

    if header_company_id && current_user
      if current_user.can_access_company?(header_company_id)
        return header_company_id
      end
    end

    current_user&.company_id
  end
end
