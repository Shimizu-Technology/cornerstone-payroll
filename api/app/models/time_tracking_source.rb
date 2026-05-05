# frozen_string_literal: true

class TimeTrackingSource < ApplicationRecord
  SOURCE_TYPES = %w[aire_services cornerstone_tax custom].freeze

  belongs_to :company
  has_many :time_tracking_employee_mappings, dependent: :destroy
  has_many :time_tracking_imports, dependent: :destroy

  encrypts :shared_secret

  validates :name, :source_type, :base_url, :shared_secret, presence: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :name, uniqueness: { scope: :company_id }
  validate :base_url_must_be_http_url
  validate :source_type_must_not_change, on: :update

  scope :active, -> { where(active: true) }

  private

  def base_url_must_be_http_url
    uri = URI.parse(base_url.to_s)
    return if uri.host.present? && uri.userinfo.blank? && uri.scheme.in?(%w[http https])

    errors.add(:base_url, "must be an HTTP or HTTPS URL")
  rescue URI::InvalidURIError
    errors.add(:base_url, "must be an HTTP or HTTPS URL")
  end

  def source_type_must_not_change
    return unless will_save_change_to_source_type?

    errors.add(:source_type, "cannot be changed after creation")
  end
end
