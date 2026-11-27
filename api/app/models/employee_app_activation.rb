# frozen_string_literal: true

# M4-9d: the Employee app switch's record that one part of a company's
# employee app was turned on after its readiness checks passed. A profile
# flag alone opens nothing: CompanyFeatures counts a part on only while the
# flag is on AND an unrevoked activation for that part exists, so a direct
# profile write, a copied row or a future-dated version can't skip the
# checks. Only EmployeeAppSwitch writes these rows (Update activates,
# ProfileWriter revokes on every turn-off). Rows are never edited except to
# revoke them once, and never deleted.
class EmployeeAppActivation < ApplicationRecord
  PARTS = OperatingProfileCatalog::EMPLOYEE_APP_SWITCH_IDS

  belongs_to :company
  belongs_to :activated_by, class_name: "User"
  belongs_to :revoked_by, class_name: "User", optional: true
  belongs_to :early_access_window, class_name: "EmployeeAppEarlyAccessWindow", optional: true

  validates :part, inclusion: { in: PARTS }
  validates :activated_at, presence: true
  validates :revoke_reason, length: { maximum: EmployeeAppSwitch::REASON_MAX }

  after_save { CompanyFeatures.clear_cache!(company_id) }
  after_destroy { CompanyFeatures.clear_cache!(company_id) }

  scope :open, -> { where(revoked_at: nil) }

  def self.open_parts_for(company_id)
    open.where(company_id: company_id).pluck(:part)
  end

  # Called by EmployeeAppSwitch::Update only, under the company lock. An
  # older open row for the part (say, left open while the profile editor
  # turned the flag off) is replaced, so the row always holds the checks
  # this turn-on passed.
  def self.activate!(company:, part:, actor:, checks:, early_access_window: nil, now: Time.current)
    revoke!(company: company, parts: [ part ], actor: actor, reason: "Turned on again after new readiness checks", now: now)
    create!(company: company, part: part, activated_by: actor, activated_at: now, checks: checks,
      early_access_window: early_access_window)
  end

  # Called by EmployeeAppSwitch::ProfileWriter for every part it turns off.
  # Returns the parts revoked.
  def self.revoke!(company:, parts:, actor:, reason:, now: Time.current)
    rows = open.where(company_id: company.id, part: parts).order(:id).lock.to_a
    rows.each do |row|
      row.update!(revoked_at: now, revoked_by: actor, revoke_reason: reason.to_s.first(EmployeeAppSwitch::REASON_MAX))
    end
    rows.map(&:part)
  end
end
