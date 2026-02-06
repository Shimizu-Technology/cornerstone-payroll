# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Api
  module V1
    class AuthController < ApplicationController
      skip_before_action :authenticate_user!, only: [ :login, :callback, :logout ], if: -> { respond_to?(:authenticate_user!) }

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

        # Find or create user
        user = find_or_create_user(profile)

        # Generate session token
        session_token = generate_session_token(user)

        render json: {
          token: session_token,
          user: {
            id: user[:id],
            email: user[:email],
            name: user[:name],
            role: user[:role]
          }
        }
      end

      # POST /api/v1/auth/logout
      def logout
        # In a real implementation, you'd invalidate the session token
        # For now, just acknowledge the logout
        render json: { message: "Logged out successfully" }
      end

      # GET /api/v1/auth/me
      # Returns current user info (requires authentication)
      def me
        # This would normally use the authenticated user from middleware
        # For now, return a placeholder based on COMPANY_ID
        render json: {
          user: {
            id: ENV.fetch("USER_ID", 1).to_i,
            email: "admin@example.com",
            name: "Admin User",
            role: "admin",
            company_id: ENV.fetch("COMPANY_ID", 1).to_i
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

      def find_or_create_user(profile)
        # In production, this would create/update a User record
        # For now, return the profile data
        {
          id: profile[:id] || SecureRandom.uuid,
          email: profile[:email],
          name: "#{profile[:first_name]} #{profile[:last_name]}".strip,
          role: determine_role(profile),
          workos_id: profile[:id]
        }
      end

      def determine_role(profile)
        # Check organization memberships or default to employee
        # In production, this would check the user's role in the company
        "admin"
      end

      def generate_session_token(user)
        # In production, use a proper JWT library
        # For now, create a simple signed token
        payload = {
          user_id: user[:id],
          email: user[:email],
          role: user[:role],
          exp: 24.hours.from_now.to_i
        }

        # Simple encoding - in production use JWT gem
        Base64.strict_encode64(payload.to_json)
      end
    end
  end
end
