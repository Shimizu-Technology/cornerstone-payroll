# frozen_string_literal: true

# How an employee write applies contact fields, shared by the admin and
# client write paths: which email and phone values really changed, checking
# and normalizing them with EmployeeContactValidator, and whether the write
# sets who entered the contact details.
class EmployeeContactChanges
  # Raised before any validation when the actor may not change an email now
  # (EmployeeContactLoginRejectionGuard's cooldown).
  class EmailChangeLocked < StandardError; end

  attr_reader :validation, :contact_source

  def self.email_changed?(employee, value)
    EmployeeContactValidator.normalize_email(employee.email) != EmployeeContactValidator.normalize_email(value)
  end

  # Reformatting the same number isn't a change; an invalid number always is,
  # so the validator reports it.
  def self.phone_changed?(employee, value)
    normalized_new, error = EmployeeContactValidator.normalize_phone(value)
    return true if error.present?

    normalized_current, = EmployeeContactValidator.normalize_phone(employee.phone)
    (normalized_current || employee.phone.presence) != normalized_new
  end

  # employee is the record compared and validated; error_record gets the
  # validation errors (the client create validates a candidate copy).
  def initialize(
    employee:, attributes:, company:, actor:, source:,
    confirm_same_person_email: false, creation: false, error_record: employee, email_locked: false
  )
    @employee = employee
    @attributes = attributes
    @company = company
    @actor = actor
    @source = source
    @confirm_same_person_email = confirm_same_person_email
    @creation = creation
    @error_record = error_record
    @email_locked = email_locked
  end

  # Normalizes email and phone in attributes in place, dropping unchanged ones
  # on an update. Raises EmployeeContactValidator::ValidationError.
  def apply!
    drop_unchanged_contact! unless @creation
    @attributes[:email] = nil if @attributes.key?(:email) && @attributes[:email].blank?
    @attributes[:phone] = nil if @attributes.key?(:phone) && @attributes[:phone].blank?
    raise EmailChangeLocked if @email_locked && @attributes[:email].present?

    if @attributes.key?(:email) || @attributes.key?(:phone)
      @validation = validate!
      @attributes[:email] = @validation.normalized_email if @attributes.key?(:email)
      @attributes[:phone] = @validation.normalized_phone if @attributes.key?(:phone)
    end
    @contact_source = @source if contact_touched?
    self
  end

  private

  def drop_unchanged_contact!
    @attributes.delete(:email) if @attributes.key?(:email) && !self.class.email_changed?(@employee, @attributes[:email])
    @attributes.delete(:phone) if @attributes.key?(:phone) && !self.class.phone_changed?(@employee, @attributes[:phone])
  end

  def validate!
    result = EmployeeContactValidator.call(
      employee: @employee,
      company: @company,
      email: @attributes.key?(:email) ? @attributes[:email] : :unchanged,
      phone: @attributes.key?(:phone) ? @attributes[:phone] : :unchanged,
      confirm_same_person_email: @confirm_same_person_email,
      actor: @actor,
      source: @source
    )
    return result if result.valid?

    result.apply_errors_to(@error_record)
    raise EmployeeContactValidator::ValidationError.new(result: result, record: @error_record)
  end

  def contact_touched?
    EmployeeContactValidator::CONTACT_FIELDS.any? do |field|
      next @attributes[field].present? if @creation
      next false unless @attributes.key?(field)

      @employee.public_send(field).presence != @attributes[field].presence
    end
  end
end
