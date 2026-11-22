# frozen_string_literal: true

require "json"

module ClerkCutover
  # Read-only inventory of local Payroll users for pre-cutover review.
  # Prints counts only to stdout; writing the full operator inventory to disk
  # requires an explicit write: true flag and uses 0600 permissions.
  class InventoryService
    class WriteRefusedError < StandardError; end

    PRIVILEGED_ROLES = %w[super_admin org_admin admin].freeze
    VALID_DISPOSITIONS = %w[migrate re-invite deactivate skip_inactive].freeze

    def initialize(user_scope: User)
      @user_scope = user_scope
    end

    def generate
      users = @user_scope.includes(:company_assignments).order(:id).map do |user|
        assigned_company_ids = user.company_assignments.map(&:company_id).uniq.sort
        cross_company = assigned_company_ids.size > 1 ||
          (assigned_company_ids.any? && assigned_company_ids != [ user.company_id ])

        {
          "user_id" => user.id,
          "old_clerk_id" => user.clerk_id,
          "old_clerk_invitation_id" => user.clerk_invitation_id,
          "email" => user.email,
          "role" => user.role,
          "active" => user.active,
          "invitation_status" => user.invitation_status,
          "company_id" => user.company_id,
          "organization_id" => user.organization_id,
          "assigned_company_ids" => assigned_company_ids,
          "suggested_disposition" => suggest_disposition(user),
          "disposition" => nil,
          "requires_independent_review" => PRIVILEGED_ROLES.include?(user.role) || cross_company
        }
      end

      {
        "version" => 1,
        "generated_at" => Time.current.iso8601,
        "summary" => build_summary(users),
        "users" => users
      }
    end

    def write!(path:, write: false)
      unless write == true
        raise WriteRefusedError, "Refusing to write inventory file without explicit write: true (WRITE=true)"
      end
      raise ArgumentError, "Output path is required" if path.blank?
      raise ArgumentError, "Refusing to write to a symlink" if File.symlink?(path)

      inventory = generate
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.chmod(0o600)
        file.write(JSON.pretty_generate(inventory))
        file.write("\n")
      end

      inventory["summary"]
    end

    private

    def suggest_disposition(user)
      return "skip_inactive" unless user.active?
      return "re-invite" if user.invitation_pending? || pending_or_blank_clerk_id?(user.clerk_id)

      "migrate"
    end

    def pending_or_blank_clerk_id?(clerk_id)
      clerk_id.blank? || clerk_id.to_s.start_with?("pending_")
    end

    def build_summary(users)
      by_suggestion = users.each_with_object(Hash.new(0)) do |entry, counts|
        counts[entry["suggested_disposition"]] += 1
      end

      {
        "total_users" => users.length,
        "active_users" => users.count { |entry| entry["active"] },
        "inactive_users" => users.count { |entry| !entry["active"] },
        "pending_invitations" => users.count { |entry| entry["invitation_status"] == "pending" },
        "bound_active_users" => users.count { |entry| entry["active"] && !pending_or_blank_clerk_id?(entry["old_clerk_id"]) },
        "unbound_active_users" => users.count { |entry| entry["active"] && pending_or_blank_clerk_id?(entry["old_clerk_id"]) },
        "requires_independent_review" => users.count { |entry| entry["requires_independent_review"] },
        "suggested_dispositions" => by_suggestion
      }
    end
  end
end
