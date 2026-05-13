# frozen_string_literal: true

class Organization < ApplicationRecord
  STATUSES = %w[active inactive].freeze

  has_many :companies, dependent: :restrict_with_error
  has_many :users, dependent: :restrict_with_error

  before_validation :normalize_slug

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }

  private

  def normalize_slug
    self.slug = name.to_s.parameterize if slug.blank? && name.present?
    self.slug = slug.to_s.parameterize if slug.present?
  end
end
