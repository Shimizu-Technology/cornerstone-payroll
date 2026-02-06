# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Api
  module V1
    class AuthController < ApplicationController
      skip_before_action :authenticate_user!, only: [ :login, :callback ], if: -> { respond_to?(:authenticate_user!) }

      # GET /api/v1/auth/login
      # Redirects to WorkOS login page
      def login
        redirect_uri = callback_url

        # Build WorkOS authorization URL
        auth_url = URI("https://api.workos.com/sso/authorize")
        auth_url.query = URI.encode_www_form({
          client_id: workos_client_id,
          redirect_uri: redirect_uri,
          response_type: "code",
          state: generate_state_token
        })

        render json: { authorization_url: auth_url.to_s }
      end

      # GET /api/v1/auth/callback
      # Handles OAuth callback from WorkOS
      def callback
        code = params[:code]
        state = params[:state]

        # Verify state token (CSRF protection)
        unless valid_state_token?(state)
          return render json: { error: "Invalid state token" }, status: :unauthorized
        end

        # Exchange code for tokens
        token_response = exchange_code_for_token(code)

        if token_response[:error]
          return render json: { error: token_response[:error] }, status: :unauthorized
        end

        # Get user profile from WorkOS
        profile = token_response[:profile]

        invite_token = params[:invite_token]
        invitation = invite_token.present? ? UserInvitation.find_by(token: invite_token) : nil

        if invitation
          if invitation.accepted_at.present? || invitation.expires_at <= Time.current
            return render json: { error: "Invitation expired" }, status: :unprocessable_entity
          end
        end

        # Find or create user
        begin
          user = find_or_create_user(profile, invitation)
        rescue ActiveRecord::RecordInvalid => e
          return render json: { error: e.message }, status: :unprocessable_entity
        end

        unless user.active?
          return render json: { error: "User is inactive" }, status: :forbidden
        end

        # Create a server-side session
        session = create_session(user, token_response[:access_token])

        # Generate session token
        session_token = generate_session_token(user, session)

        render json: {
          token: session_token,
          user: {
            id: user.id,
            email: user.email,
            name: user.name,
            role: user.role,
            company_id: user.company_id
          }
        }
      end

      # POST /api/v1/auth/logout
      def logout
        current_session&.revoke!
        render json: { message: "Logged out successfully" }
      end

      # GET /api/v1/auth/me
      # Returns current user info (requires authentication)
      def me
        # Return authenticated user
        user = current_user
        render json: {
          user: {
            id: user.is_a?(User) ? user.id : user[:id],
            email: user.is_a?(User) ? user.email : user[:email],
            name: user.is_a?(User) ? user.name : (user[:name] || "Admin User"),
            role: user.is_a?(User) ? user.role : user[:role],
            company_id: user.is_a?(User) ? user.company_id : user[:company_id]
          }
        }
      end

      private

      def workos_client_id
        ENV.fetch("WORKOS_CLIENT_ID")
      end

      def workos_api_key
        ENV.fetch("WORKOS_API_KEY")
      end

      def callback_url
        # Use frontend callback URL for SPA flow
        ENV.fetch("WORKOS_REDIRECT_URI", "http://localhost:5173/callback")
      end

      def generate_state_token
        # Generate a random state token and store it (in production, use Redis/session)
        token = SecureRandom.hex(32)
        Rails.cache.write("workos_state_#{token}", true, expires_in: 10.minutes)
        token
      end

      def valid_state_token?(token)
        return true if Rails.env.development? # Skip in dev for easier testing
        Rails.cache.read("workos_state_#{token}").present?
      end

      def exchange_code_for_token(code)
        uri = URI("https://api.workos.com/sso/token")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"

        request.body = URI.encode_www_form({
          client_id: workos_client_id,
          client_secret: workos_api_key,
          grant_type: "authorization_code",
          code: code,
          redirect_uri: callback_url
        })

        response = http.request(request)
        data = JSON.parse(response.body, symbolize_names: true)

        if response.code.to_i == 200
          # WorkOS returns profile directly in the token response
          data
        else
          { error: data[:message] || "Token exchange failed" }
        end
      rescue StandardError => e
        Rails.logger.error("WorkOS token exchange failed: #{e.message}")
        { error: "Authentication failed" }
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

      def find_or_create_user(profile, invitation)
        email = profile[:email]
        user = User.find_by(workos_id: profile[:id]) || User.find_by(email: email)

        # Security: Only use company_id from invitation, never from WorkOS profile.
        # Fall back to ENV default only for the very first user (bootstrap case).
        company_id = if invitation
                       invitation.company_id
        elsif user&.company_id
                       user.company_id
        elsif User.count.zero?
                       # First user ever - use ENV default
                       ENV.fetch("COMPANY_ID", 1).to_i
        else
                       raise ActiveRecord::RecordInvalid.new(User.new), "User not invited"
        end

        if user.nil?
          # Require invitation unless this is the first user in the system
          if invitation.nil? && User.exists?
            raise ActiveRecord::RecordInvalid.new(User.new), "User not invited"
          end
          user = User.new(workos_id: profile[:id])
        end

        user.company_id ||= company_id
        user.email = email
        profile_name = "#{profile[:first_name]} #{profile[:last_name]}".strip
        user.name = profile_name.presence || invitation&.name || email
        user.role ||= invitation&.role || default_role_for(user.company_id)
        user.last_login_at = Time.current
        user.active = true if user.active.nil?
        user.save!

        if invitation
          if invitation.email.casecmp(email).zero?
            invitation.accept!
          else
            raise ActiveRecord::RecordInvalid.new(user), "Invitation email mismatch"
          end
        end

        user
      end

      def default_role_for(company_id)
        return "admin" if User.where(company_id: company_id).count.zero?
        ENV.fetch("DEFAULT_USER_ROLE", "employee")
      end

      def generate_session_token(user, session)
        # Signed JWT for API authentication
        payload = {
          user_id: user.id,
          email: user.email,
          name: user.name,
          role: user.role,
          company_id: user.company_id,
          iss: jwt_issuer,
          iat: Time.current.to_i,
          jti: session.jti,
          exp: session.expires_at.to_i
        }

        JWT.encode(payload, jwt_secret, jwt_algorithm)
      end

      def create_session(user, access_token)
        UserSession.create!(
          user: user,
          jti: SecureRandom.uuid,
          expires_at: 24.hours.from_now,
          workos_access_token: access_token,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end
    end
  end
end
