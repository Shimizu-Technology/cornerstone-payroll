# frozen_string_literal: true

class User < ApplicationRecord
  INVITATION_STATUSES = %w[pending accepted].freeze

  belongs_to :company
  belongs_to :invited_by, class_name: "User", optional: true
  has_many :user_sessions, dependent: :destroy
  has_many :audit_logs, dependent: :nullify
  has_many :user_invitations, foreign_key: :invited_by_id, dependent: :nullify
  has_many :company_assignments, dependent: :destroy
  has_many :assigned_companies, through: :company_assignments, source: :company

  enum :role, { admin: 0, manager: 1, employee: 2, accountant: 3 }

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :role, presence: true
  validates :invitation_status, inclusion: { in: INVITATION_STATUSES }

  scope :active, -> { where(active: true) }

  def invitation_pending?
    invitation_status == "pending"
  end

  def invitation_accepted?
    invitation_status == "accepted"
  end

  def mark_invitation_accepted!
    update!(invitation_status: "accepted")
  end

  # Returns all companies this user can access:
  # - super_admin: all companies
  # - staff with assignments: home company + assigned companies
  # - everyone else: just their home company
  def accessible_company_ids
    @accessible_company_ids ||= begin
      if super_admin? || admin?
        Company.ids
      else
        assigned_ids = if association(:company_assignments).loaded?
          company_assignments.map(&:company_id)
        else
          company_assignments.pluck(:company_id)
        end

        if accountant? || manager?
          # Accountants/managers only see companies explicitly assigned to them
          assigned_ids.presence || [company_id]
        else
          ([company_id] + assigned_ids).uniq
        end
      end
    end
  end

  def can_access_company?(cid)
    return true if super_admin? || admin?

    accessible_company_ids.include?(cid)
  end
end
