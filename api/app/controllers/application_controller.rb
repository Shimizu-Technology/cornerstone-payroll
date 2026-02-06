require "net/http"
require "uri"

class ApplicationController < ActionController::API
  before_action :authenticate_user!
  after_action :log_audit_action, if: :audit_logging_enabled?

  private

  def authenticate_user!
    if auth_disabled?
      @current_user = fallback_user
      return
    end

    token = bearer_token
    payload = token.present? ? decode_token(token) : nil

    unless payload
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    session = UserSession.active.find_by(jti: payload["jti"])
    unless session && session.user_id.to_s == payload["user_id"].to_s
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    user = session.user
    unless user&.active?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    @current_user = user
    @current_session = session

    if verify_workos_session? && session.workos_access_token.present?
      unless workos_session_valid?(session.workos_access_token)
        session.revoke!
        render json: { error: "Unauthorized" }, status: :unauthorized
        return
      end
    end
  end

  def current_user
    @current_user || fallback_user
  end

  def current_user_id
    current_user.is_a?(User) ? current_user.id : Integer(current_user[:id], exception: false)
  end

  def current_company_id
    current_user.is_a?(User) ? current_user.company_id : current_user[:company_id]
  end

  def current_user_role
    current_user.is_a?(User) ? current_user.role : current_user[:role]
  end

  def current_session
    @current_session
  end

  def require_admin_or_manager!
    authorize_roles!("admin", "manager")
  end

  def require_admin!
    authorize_roles!("admin")
  end

  def authorize_roles!(*roles)
    return if auth_disabled?

    unless roles.include?(current_user_role)
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end
  end

  def bearer_token
    auth_header = request.headers["Authorization"].to_s
    return if auth_header.blank?

    scheme, token = auth_header.split(" ", 2)
    scheme == "Bearer" ? token : nil
  end

  def decode_token(token)
    payload, = JWT.decode(
      token,
      jwt_secret,
      true,
      {
        algorithm: jwt_algorithm,
        verify_expiration: true,
        verify_iss: true,
        iss: jwt_issuer,
        leeway: 10
      }
    )
    payload
  rescue JWT::DecodeError
    nil
  end

  def auth_disabled?
    ENV.fetch("AUTH_ENABLED", "true").to_s.downcase == "false"
  end

  def jwt_secret
    ENV.fetch("JWT_SECRET", Rails.application.secret_key_base)
  end

  def jwt_issuer
    ENV.fetch("JWT_ISSUER", "cornerstone-payroll")
  end

  def jwt_algorithm
    "HS256"
  end

  def verify_workos_session?
    ENV.fetch("VERIFY_WORKOS_SESSION", "false").to_s.downcase == "true"
  end

  def workos_session_valid?(access_token)
    uri = URI("https://api.workos.com/sso/profile")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    response = http.request(request)
    response.code.to_i == 200
  rescue StandardError => e
    Rails.logger.error("WorkOS session validation failed: #{e.message}")
    false
  end

  def audit_logging_enabled?
    return false if request.get?
    return false if params[:controller].to_s.start_with?("api/v1/auth")
    response.status < 400
  end

  def log_audit_action
    AuditLog.record!(
      user: current_user.is_a?(User) ? current_user : nil,
      company_id: current_company_id,
      action: "#{controller_name}##{action_name}",
      record_type: params[:controller],
      record_id: params[:id],
      metadata: {
        method: request.request_method,
        path: request.path,
        params: request.filtered_parameters.except("controller", "action")
      },
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  rescue StandardError => e
    Rails.logger.error("Audit log failed: #{e.message}")
  end

  def fallback_user
    user_id = ENV.fetch("USER_ID", 1).to_i
    User.find_by(id: user_id) || {
      id: user_id,
      email: "admin@example.com",
      name: "Admin User",
      role: "admin",
      company_id: ENV.fetch("COMPANY_ID", 1).to_i
    }
  end
end
