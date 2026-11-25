# frozen_string_literal: true

require "digest"

class DeliveryDisclosure < ApplicationRecord
  KINDS = %w[pay_statements w2gu].freeze
  STATUSES = %w[draft approved].freeze
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

  has_many :delivery_consents, dependent: :restrict_with_exception

  before_validation :compute_digest

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :version, presence: true, uniqueness: { scope: :kind }
  validates :title, presence: true
  validates :text, presence: true
  validates :digest, presence: true, format: { with: DIGEST_PATTERN }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :digest_matches_text

  scope :for_kind, ->(kind) { where(kind: kind.to_s) }
  scope :published, -> { where.not(published_at: nil) }
  scope :approved, -> { where(status: "approved") }
  scope :draft, -> { where(status: "draft") }
  scope :latest_first, -> { order(published_at: :desc, id: :desc) }

  def self.digest_for(text)
    Digest::SHA256.hexdigest(text.to_s)
  end

  # Prefer the latest published approved disclosure for a kind; fall back to
  # the latest published draft disclosure while legal review is pending.
  def self.current_for(kind)
    scope = for_kind(kind).published
    scope.approved.latest_first.first || scope.draft.latest_first.first
  end

  def approved?
    status == "approved"
  end

  def draft?
    status == "draft"
  end

  private

  def compute_digest
    self.digest = self.class.digest_for(text) if digest.blank? && text.present?
  end

  def digest_matches_text
    return if text.blank? || digest.blank?

    expected = self.class.digest_for(text)
    errors.add(:digest, "must match SHA-256 digest of text") unless digest == expected
  end
end
