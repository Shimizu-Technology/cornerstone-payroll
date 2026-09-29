# frozen_string_literal: true

require "digest"
require "securerandom"

class FinanceApiToken < ApplicationRecord
  PREFIX = "cfin_"
  TOKEN_PATTERN = /\A#{PREFIX}[a-f0-9]{64}\z/
  SCOPES = %w[read draft_write].freeze

  belongs_to :organization
  belongs_to :finance_book
  belongs_to :created_by, class_name: "User"

  validates :name, presence: true, length: { maximum: 80 }
  validates :token_digest, presence: true, uniqueness: true
  validates :scopes, presence: true
  validate :known_scopes
  validate :book_matches_organization

  def self.issue!(finance_book:, actor:, name:, scopes: [ "read" ], expires_at: 90.days.from_now)
    secret = "#{PREFIX}#{SecureRandom.hex(32)}"
    token = create!(finance_book: finance_book, organization: finance_book.organization, created_by: actor,
                    name: name, token_digest: Digest::SHA256.hexdigest(secret), scopes: scopes,
                    expires_at: expires_at)
    [ token, secret ]
  end

  def self.authenticate(secret)
    return nil unless secret.is_a?(String) && TOKEN_PATTERN.match?(secret)

    token = includes(:finance_book, :organization, :created_by)
            .find_by(token_digest: Digest::SHA256.hexdigest(secret))
    token if token&.usable?
  end

  def usable?
    revoked_at.nil? && expires_at.future? && organization.active? && finance_book.active? && scopes.include?("read") &&
      created_by.payroll_access_allowed? && StaffRolePolicy.allowed?(created_by, :manage_organization) &&
      (created_by.super_admin? || created_by.organization_id == organization_id) &&
      (finance_book.kind != "personal" || finance_book.owner_user_id == created_by_id) &&
      (finance_book.company_id.nil? || created_by.can_access_company?(finance_book.company_id))
  end

  private

  def known_scopes
    errors.add(:scopes, "are invalid") unless scopes.is_a?(Array) && scopes.all? { |scope| SCOPES.include?(scope) }
    errors.add(:scopes, "must include read access") unless scopes.is_a?(Array) && scopes.include?("read")
    errors.add(:scopes, "cannot contain duplicates") if scopes.is_a?(Array) && scopes.uniq.length != scopes.length
  end

  def book_matches_organization
    return if finance_book.blank? || organization.blank? || finance_book.organization_id == organization_id

    errors.add(:finance_book, "must belong to the selected organization")
  end
end
