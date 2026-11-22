# frozen_string_literal: true

require "json"

module ClerkCutover
  # Builds the sealed email-free re-link manifest after `clerk migrate import`
  # has populated the target Clerk production instance.
  #
  # Joins local/inventory users to target Clerk production users STRICTLY by
  # `target_user["external_id"] == old_clerk_id` — zero email matching.
  class RelinkManifestBuilder
    class ValidationError < StandardError; end
    class WriteRefusedError < StandardError; end

    def initialize(target_users:, inventory: nil, user_scope: User)
      @target_users = extract_target_users(target_users)
      @inventory_rows = inventory.nil? ? nil : extract_inventory_rows(inventory)
      @user_scope = user_scope
    end

    def build
      target_by_external_id = index_target_users!
      source_rows = load_source_rows

      errors = []
      entries = []
      seen_new_ids = Set.new

      source_rows.each do |row|
        user_id = row[:user_id]
        old_clerk_id = row[:old_clerk_id]

        if old_clerk_id.blank? || old_clerk_id.start_with?("pending_")
          errors << "user_id=#{user_id}: cannot build manifest entry for blank or pending old_clerk_id"
          next
        end

        target = target_by_external_id[old_clerk_id]
        unless target
          errors << "user_id=#{user_id}: no target Clerk user found with external_id=#{old_clerk_id}"
          next
        end

        new_clerk_id = target["id"].to_s.strip
        if new_clerk_id.empty? || new_clerk_id.start_with?("pending_")
          errors << "user_id=#{user_id}: target Clerk user has invalid id"
          next
        end

        if new_clerk_id == old_clerk_id
          errors << "user_id=#{user_id}: target new_clerk_id equals old_clerk_id (#{old_clerk_id})"
          next
        end

        unless seen_new_ids.add?(new_clerk_id)
          errors << "user_id=#{user_id}: duplicate target new_clerk_id #{new_clerk_id}"
          next
        end

        entries << {
          "user_id" => user_id,
          "old_clerk_id" => old_clerk_id,
          "new_clerk_id" => new_clerk_id,
          "external_id" => old_clerk_id
        }
      end

      raise ValidationError, errors.join("; ") if errors.any?
      raise ValidationError, "No users matched for re-link manifest" if entries.empty?

      manifest = {
        "version" => 1,
        "generated_at" => Time.current.iso8601,
        "matching_strategy" => "external_id",
        "entries" => entries
      }

      {
        manifest: manifest,
        summary: {
          "matching_strategy" => "external_id",
          "source_users" => source_rows.length,
          "target_users" => @target_users.length,
          "manifest_entries" => entries.length
        }
      }
    end

    def write!(path:, write: false)
      unless write == true
        raise WriteRefusedError, "Refusing to write manifest file without explicit write: true (WRITE=true)"
      end
      raise ArgumentError, "Output path is required" if path.blank?

      result = build
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.pretty_generate(result[:manifest]))
        file.write("\n")
      end

      result[:summary]
    end

    private

    def extract_target_users(target_users)
      parsed = target_users.is_a?(String) ? JSON.parse(target_users) : target_users
      rows = parsed.is_a?(Hash) ? (parsed["users"] || parsed["data"]) : parsed
      raise ValidationError, "Target Clerk users must be an array" unless rows.is_a?(Array)

      rows.map { |row| row.transform_keys(&:to_s) }
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid target Clerk users JSON: #{e.message}"
    end

    def extract_inventory_rows(inventory)
      parsed = inventory.is_a?(String) ? JSON.parse(inventory) : inventory
      rows = parsed.is_a?(Hash) ? parsed["users"] : parsed
      raise ValidationError, "Inventory must contain a 'users' array" unless rows.is_a?(Array)

      rows.map { |row| row.transform_keys(&:to_s) }
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid inventory JSON: #{e.message}"
    end

    def load_source_rows
      if @inventory_rows
        @inventory_rows
          .select { |row| row["disposition"] == "migrate" }
          .map { |row| { user_id: row["user_id"], old_clerk_id: row["old_clerk_id"].to_s.strip } }
      else
        @user_scope
          .where(active: true)
          .where.not(clerk_id: [ nil, "" ])
          .order(:id)
          .reject { |user| user.clerk_id.start_with?("pending_") }
          .map { |user| { user_id: user.id, old_clerk_id: user.clerk_id } }
      end
    end

    def index_target_users!
      indexed = {}
      @target_users.each do |target|
        external_id = target["external_id"].to_s.strip
        next if external_id.empty?

        if indexed.key?(external_id)
          raise ValidationError, "Target Clerk instance has duplicate external_id #{external_id}"
        end

        indexed[external_id] = target
      end
      indexed
    end
  end
end
