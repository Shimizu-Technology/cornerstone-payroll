# frozen_string_literal: true

# The Employee App Terms of Use and Privacy Notice versions (counsel tracker
# item 1). Rows are immutable: counsel's approval inserts a new approved
# version. The switch readiness check reads the current version's status.
class EmployeeTermsVersion < ApplicationRecord
  TITLE = "Employee App Terms"
  validates :text_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true

  STATUSES = %w[draft approved].freeze

  validates :version, presence: true, uniqueness: true, length: { maximum: 80 }
  validates :status, inclusion: { in: STATUSES }
  validates :terms_url, :privacy_url, presence: true, length: { maximum: 500 },
    format: { with: %r{\A(https://[^\s]+|/[^/\s][^\s]*)\z}, message: "must be an https:// address or a site path" }
  validates :published_at, presence: true

  scope :latest_first, -> { order(published_at: :desc, id: :desc) }

  def readonly?
    persisted?
  end

  # The latest approved version, or the latest draft while counsel reviews.
  def self.current
    where(status: "approved").latest_first.first || where(status: "draft").latest_first.first
  end

  def approved?
    status == "approved"
  end
end
