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

  # Resolve the active company for this request.
  # Priority: X-Company-Id header (if user can access it) → user's home company → first accessible company.
  def resolve_company_id
    return current_user&.company_id unless current_user

    header_company_id = request.headers["X-Company-Id"].presence&.to_i

    if header_company_id && current_user.can_access_company?(header_company_id)
      return header_company_id
    end

    # Fall back to home company if accessible, otherwise first assigned company
    home = current_user.company_id
    if current_user.can_access_company?(home)
      home
    else
      current_user.accessible_company_ids.first || home
    end
  end
end
