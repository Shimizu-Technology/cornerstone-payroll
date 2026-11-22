# frozen_string_literal: true

require "csv"
require "json"

module ClerkCutover
  # Builds a `clerk migrate import`-compatible payload from a human-reviewed
  # Payroll user inventory and a Clerk Dashboard user export (CSV or JSON).
  #
  # Matching is performed STRICTLY by old_clerk_id == export["id"] (the dev
  # Clerk user ID), setting `external_id` = old_clerk_id on every imported user.
  # Email addresses are NEVER used as a join key.
  class ImportBuilder
    class ValidationError < StandardError; end
    class WriteRefusedError < StandardError; end

    VALID_DISPOSITIONS = InventoryService::VALID_DISPOSITIONS
    TRUTHY_VALUES = %w[1 true t yes y on].freeze
    RECOGNIZED_MFA_FIELDS = %w[
      totp_enabled
      two_factor_enabled
      backup_code_enabled
      totp_secret
      backup_codes
      backup_code_digests
    ].freeze

    def initialize(inventory:, clerk_export:, batch: nil)
      @inventory_rows = extract_inventory_rows(inventory)
      @export_rows = parse_clerk_export(clerk_export)
      @batch = batch.nil? || batch.to_s.strip.empty? ? nil : batch.to_s.strip
    end

    def build
      validate_inventory_rows!
      export_by_id = index_export_rows!

      migrating_rows = @inventory_rows.select do |row|
        row["disposition"] == "migrate" && batch_matches?(row)
      end

      errors = []
      records = []

      migrating_rows.each do |row|
        user_id = row["user_id"]
        old_clerk_id = row["old_clerk_id"].to_s.strip

        if old_clerk_id.empty? || old_clerk_id.start_with?("pending_")
          errors << "user_id=#{user_id}: disposition 'migrate' requires a non-pending old_clerk_id"
          next
        end

        exported = export_by_id[old_clerk_id]
        unless exported
          errors << "user_id=#{user_id}: old_clerk_id #{old_clerk_id} was not found in the Clerk Dashboard export"
          next
        end

        if exported[:totp_enabled]
          errors << "user_id=#{user_id}: clerk_id #{old_clerk_id} has TOTP enrolled and cannot be silently migrated"
          next
        end

        if exported[:emails].empty?
          errors << "user_id=#{user_id}: clerk_id #{old_clerk_id} has no email address in the Clerk Dashboard export"
          next
        end

        record = {
          "external_id" => old_clerk_id,
          "email_address" => exported[:emails]
        }
        record["first_name"] = exported[:first_name] if exported[:first_name].present?
        record["last_name"] = exported[:last_name] if exported[:last_name].present?

        if exported[:password_digest].present?
          record["password_digest"] = exported[:password_digest]
          record["password_hasher"] = exported[:password_hasher].presence || "bcrypt"
        else
          record["skip_password_requirement"] = true
        end

        records << record
      end

      raise ValidationError, errors.join("; ") if errors.any?

      {
        records: records,
        summary: {
          "batch" => @batch,
          "inventory_rows" => @inventory_rows.length,
          "selected_for_import" => records.length,
          "with_password_digest" => records.count { |record| record["password_digest"].present? },
          "without_password_digest" => records.count { |record| record["password_digest"].blank? },
          "dispositions" => @inventory_rows.map { |row| row["disposition"] }.tally
        }
      }
    end

    def write!(path:, write: false)
      unless write == true
        raise WriteRefusedError, "Refusing to write import file without explicit write: true (WRITE=true)"
      end
      raise ArgumentError, "Output path is required" if path.blank?
      raise ArgumentError, "Refusing to write to a symlink" if File.symlink?(path)

      result = build
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.chmod(0o600)
        file.write(JSON.pretty_generate(result[:records]))
        file.write("\n")
      end

      result[:summary]
    end

    private

    def extract_inventory_rows(inventory)
      parsed = inventory.is_a?(String) ? JSON.parse(inventory) : inventory
      rows = parsed.is_a?(Hash) ? parsed["users"] : parsed
      raise ValidationError, "Inventory must contain a 'users' array" unless rows.is_a?(Array)

      rows.map { |row| row.transform_keys(&:to_s) }
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid inventory JSON: #{e.message}"
    end

    def parse_clerk_export(clerk_export)
      if clerk_export.is_a?(Array)
        return clerk_export.each_with_index.map do |row, index|
          normalize_json_export_row(row.transform_keys(&:to_s), index)
        end
      end

      if clerk_export.is_a?(Hash)
        rows = clerk_export["users"] || clerk_export["data"]
        raise ValidationError, "Clerk export object must contain 'users' or 'data' array" unless rows.is_a?(Array)

        return rows.each_with_index.map do |row, index|
          normalize_json_export_row(row.transform_keys(&:to_s), index)
        end
      end

      raw = clerk_export.to_s
      stripped = raw.lstrip
      if stripped.start_with?("[", "{")
        parse_clerk_export(JSON.parse(raw))
      else
        parse_csv_export(raw)
      end
    rescue JSON::ParserError, CSV::MalformedCSVError => e
      raise ValidationError, "Invalid Clerk export format: #{e.message}"
    end

    def parse_csv_export(raw)
      table = CSV.parse(raw, headers: true)
      headers = Array(table.headers).compact.map { |header| header.to_s.strip }
      if (headers & RECOGNIZED_MFA_FIELDS).empty?
        raise ValidationError,
          "Clerk export is missing recognized MFA/TOTP columns (#{RECOGNIZED_MFA_FIELDS.join(', ')}); cannot verify zero TOTP enrollment"
      end

      table.map do |row|
        hash = row.to_h.transform_keys { |key| key.to_s.strip }
        emails = extract_csv_emails(hash)
        {
          id: hash["id"].to_s.strip,
          first_name: hash["first_name"].to_s.strip.presence,
          last_name: hash["last_name"].to_s.strip.presence,
          emails: emails,
          password_digest: hash["password_digest"].to_s.strip.presence,
          password_hasher: hash["password_hasher"].to_s.strip.presence,
          totp_enabled: mfa_enrolled?(hash)
        }
      end
    end

    def normalize_json_export_row(row, index)
      if (row.keys & RECOGNIZED_MFA_FIELDS).empty?
        raise ValidationError,
          "Clerk export row #{index} is missing recognized MFA/TOTP fields (#{RECOGNIZED_MFA_FIELDS.join(', ')}); cannot verify zero TOTP enrollment"
      end

      emails = extract_json_emails(row)
      {
        id: row["id"].to_s.strip,
        first_name: row["first_name"].to_s.strip.presence,
        last_name: row["last_name"].to_s.strip.presence,
        emails: emails,
        password_digest: row["password_digest"].to_s.strip.presence,
        password_hasher: row["password_hasher"].to_s.strip.presence,
        totp_enabled: mfa_enrolled?(row)
      }
    end

    def mfa_enrolled?(hash)
      truthy?(hash["totp_enabled"]) ||
        truthy?(hash["two_factor_enabled"]) ||
        truthy?(hash["backup_code_enabled"]) ||
        non_empty_mfa_material?(hash["totp_secret"]) ||
        non_empty_mfa_material?(hash["backup_codes"]) ||
        non_empty_mfa_material?(hash["backup_code_digests"])
    end

    def non_empty_mfa_material?(value)
      return false if value.nil? || value == false
      return value.reject(&:blank?).any? if value.is_a?(Array)

      stripped = value.to_s.strip
      return false if stripped.empty?

      !%w[[] {} null false].include?(stripped.downcase)
    end

    def extract_csv_emails(hash)
      candidates = []
      candidates << hash["primary_email_address"]
      candidates << hash["email_address"]
      if hash["verified_email_addresses"].present?
        candidates.concat(hash["verified_email_addresses"].to_s.split(/[,;]/))
      end

      candidates.filter_map { |value| value.to_s.strip.downcase.presence }.uniq
    end

    def extract_json_emails(row)
      if row["email_addresses"].is_a?(Array)
        primary_id = row["primary_email_address_id"]
        sorted = row["email_addresses"].sort_by { |addr| addr["id"] == primary_id ? 0 : 1 }
        return sorted.filter_map do |addr|
          next unless addr.is_a?(Hash)

          addr["email_address"].to_s.strip.downcase.presence
        end.uniq
      end

      raw = row["email_address"] || row["primary_email_address"]
      Array(raw).filter_map { |value| value.to_s.strip.downcase.presence }.uniq
    end

    def validate_inventory_rows!
      errors = []
      seen_user_ids = Set.new
      seen_clerk_ids = Set.new

      @inventory_rows.each_with_index do |row, index|
        user_id = row["user_id"]
        disposition = row["disposition"].to_s.strip

        if user_id.nil? || !user_id.is_a?(Integer)
          errors << "inventory row #{index}: user_id must be an integer"
        elsif !seen_user_ids.add?(user_id)
          errors << "inventory row #{index}: duplicate user_id #{user_id}"
        end

        unless VALID_DISPOSITIONS.include?(disposition)
          errors << "user_id=#{user_id}: disposition must be one of #{VALID_DISPOSITIONS.join(', ')}"
        end

        clerk_id = row["old_clerk_id"].to_s.strip
        if clerk_id.present? && !seen_clerk_ids.add?(clerk_id)
          errors << "user_id=#{user_id}: duplicate old_clerk_id #{clerk_id}"
        end
      end

      raise ValidationError, errors.join("; ") if errors.any?
    end

    def index_export_rows!
      indexed = {}
      @export_rows.each_with_index do |row, index|
        clerk_id = row[:id]
        raise ValidationError, "Clerk export row #{index}: missing id" if clerk_id.blank?
        raise ValidationError, "Clerk export contains duplicate id #{clerk_id}" if indexed.key?(clerk_id)

        indexed[clerk_id] = row
      end
      indexed
    end

    def batch_matches?(row)
      return true if @batch.nil?

      row["batch"].to_s.strip == @batch
    end

    def truthy?(value)
      return true if value == true
      return false if value == false || value.nil?

      TRUTHY_VALUES.include?(value.to_s.strip.downcase)
    end
  end
end
