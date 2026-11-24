# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocuments::PdfImageReview do
  def page_with_soft_mask
    document = Prawn::Document.new
    document.text("QuickBooks stub")
    document.state.page.resources[:ExtGState] = {
      NoMask: document.state.store.ref(Type: :ExtGState, SMask: :None),
      Masked: document.state.store.ref(Type: :ExtGState, SMask: yield(document))
    }
    document.add_content("/NoMask gs /Masked gs")
    PDF::Reader.new(StringIO.new(document.render)).page(1)
  end

  it "requires review when the only image is in a soft mask's transparency group" do
    page = page_with_soft_mask do |document|
      png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aBakAAAAASUVORK5CYII=")
      image, = document.build_image_object(StringIO.new(png))
      group = document.state.store.ref(Type: :XObject, Subtype: :Form, BBox: [ 0, 0, 1, 1 ],
        Group: { S: :Transparency, CS: :DeviceGray }, Resources: { XObject: { MaskImage: image } })
      group.stream << "/MaskImage Do"
      document.state.store.ref(S: :Luminosity, G: group)
    end

    expect(described_class.new(page).required?).to be(true)
  end

  it "does not require review when the soft mask is a PDF name" do
    page = page_with_soft_mask { :None }

    expect(described_class.new(page).required?).to be_falsey
  end
end
