# frozen_string_literal: true

class Organization < ApplicationRecord
  STATUSES = %w[active inactive].freeze

  has_many :companies, dependent: :restrict_with_error
  has_many :users, dependent: :restrict_with_error
  belongs_to :primary_company, class_name: "Company", optional: true

  before_validation :normalize_slug

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :client_limit, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :primary_company_must_belong_to_organization

  scope :active, -> { where(status: "active") }

  def unlimited_clients?
    client_limit.nil?
  end

  def client_limit_reached?
    client_limit.present? && companies.count >= client_limit
  end

  private

  def normalize_slug
    self.slug = name.to_s.parameterize if slug.blank? && name.present?
    self.slug = slug.to_s.parameterize if slug.present?
  end

  def primary_company_must_belong_to_organization
    return if primary_company.blank? || id.blank?
    return if primary_company.organization_id == id

    errors.add(:primary_company, "must belong to this organization")
  end
end
