# frozen_string_literal: true

module DemoCompany
  # Invites the demo employer's two client personas (a manager and a regular
  # client user) through the normal client invitation: a Payroll client login
  # on the demo company, a Clerk invitation and the invite email. Addresses
  # come from the caller (private configuration), must be allow-listed and are
  # never stored in the repository. Safe to rerun: an invited or bound login is
  # left as it is.
  class InviteClients
    class Refused < StandardError; end

    Persona = Data.define(:name, :email)
    Outcome = Data.define(:email, :status)

    MANAGER_NAME = "Maren Fable"
    USER_NAME = "Tessa Vale"

    def initialize(organization:, actor:, manager_email:, user_email:, invitation: PayrollInvitation.new, redirect_url: nil)
      @organization = organization
      @actor = actor
      @personas = [ Persona.new(MANAGER_NAME, manager_email.to_s), Persona.new(USER_NAME, user_email.to_s) ]
      @invitation = invitation
      @redirect_url = redirect_url || "#{ENV.fetch('FRONTEND_URL') { ENV.fetch('ALLOWED_ORIGINS', 'http://localhost:5173').split(',').first.strip }}/login"
    end

    def call
      authorize!
      company = kitchen
      emails = @personas.map { |persona| DemoOutbound.normalize(persona.email) }
      raise Refused, "Give two different addresses" if emails.any?(&:nil?) || emails.uniq.size != emails.size
      refused = @personas.reject { |persona| DemoOutbound.allowed?(persona.email) }
      raise Refused, "#{refused.size} address(es) aren't on the allow-list; nothing was sent" if refused.any?

      @personas.map { |persona| invite!(company, persona) }
    end

    private

    attr_reader :organization, :actor

    def authorize!
      allowed = organization.present? && actor&.organization_admin? && actor.payroll_access_allowed? &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Refused, "An organization administrator is required" unless allowed
    end

    def kitchen
      company = TenantScope.as_system(reason: "Find the demo employer to invite clients to") do
        Company.demo.where(organization_id: organization.id)
          .find_by("test_workspace_manifest ->> 'demo_fixture_key' = ?", Roster::KITCHEN)
      end
      company || raise(Refused, "Seed the demo employers first (rake demo:seed)")
    end

    def invite!(company, persona)
      email = DemoOutbound.normalize(persona.email)
      user = TenantScope.as_system(reason: "Find or create a demo client login") { find_or_create_login!(company, persona, email) }
      return Outcome.new(email: email, status: "already_active") unless user.awaiting_clerk_binding?
      return Outcome.new(email: email, status: "already_invited") if user.clerk_invitation_id.present?

      result = @invitation.send_invite(user, redirect_url: @redirect_url)
      return Outcome.new(email: email, status: "failed: #{result[:error]}") unless result[:success]

      sent = UserInviteEmailService.send_invite(user: user, invited_by: actor, invitation_url: result[:url])
      Outcome.new(email: email, status: sent == true ? "invited" : "invited_without_email")
    end

    def find_or_create_login!(company, persona, email)
      existing = User.where("lower(email) = ?", email).first
      if existing
        unless existing.client? && existing.company_id == company.id
          raise Refused, "#{persona.name}'s address already belongs to another login"
        end
        return existing
      end

      User.transaction do
        user = User.create!(email: email, name: persona.name, role: "client", company: company, organization: organization,
          clerk_id: "pending_#{SecureRandom.uuid}", invitation_status: "pending", invited_by: actor, invited_at: Time.current,
          active: true)
        CompanyAssignment.create!(user: user, company: company, granted_by: actor)
        AuditLog.record!(user: actor, organization_id: organization.id, company_id: company.id, action: "users#created",
          record_type: "users", record_id: user.id, subject_name: user.name, metadata: { role: "client" })
        user
      end
    end
  end
end
