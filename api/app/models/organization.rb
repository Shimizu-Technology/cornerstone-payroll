# frozen_string_literal: true

class Organization < ApplicationRecord
  STATUSES = %w[active inactive].freeze

  has_many :companies, dependent: :restrict_with_error
  has_many :users, dependent: :restrict_with_error
  has_many :printer_profiles, dependent: :destroy
  has_many :invoice_billing_profiles, dependent: :restrict_with_error
  has_many :invoice_recipients, dependent: :restrict_with_error
  has_many :invoices, dependent: :restrict_with_error
  has_many :invoice_chat_sessions, dependent: :restrict_with_error
  has_many :invoice_number_sequences, dependent: :restrict_with_error
  has_many :invoice_artifacts, dependent: :restrict_with_error
  has_many :invoice_events, dependent: :restrict_with_error
  has_many :invoice_payments, dependent: :restrict_with_error
  has_many :invoice_credit_notes, dependent: :restrict_with_error
  has_many :invoice_deliveries, dependent: :restrict_with_error
  belongs_to :primary_company, class_name: "Company", optional: true

  before_validation :normalize_slug
  after_update_commit :disconnect_cable_users_after_deactivation, if: :saved_change_to_status?

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :client_limit, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :primary_company_must_belong_to_organization

  scope :active, -> { where(status: "active") }

  def unlimited_clients?
    client_limit.nil?
  end

  def active?
    status == "active"
  end

  def save_company_within_client_limit!(company)
    with_lock do
      if client_limit.present? && companies.count >= client_limit
        company.errors.add(:base, "Client limit reached for this organization")
        raise ActiveRecord::RecordInvalid, company
      end

      company.save!
    end
  end

  private

  def disconnect_cable_users_after_deactivation
    return if active?

    users.where.not(role: User.roles.fetch("super_admin")).find_each do |user|
      PayrollAccess::SessionRevoker.disconnect_user(user)
    end
  end

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
