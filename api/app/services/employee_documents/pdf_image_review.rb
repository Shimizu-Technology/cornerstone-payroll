# frozen_string_literal: true

module EmployeeDocuments
  class PdfImageReview
    class InlineImageProbe
      attr_reader :found

      def begin_inline_image
        @found = true
      end
    end

    def initialize(page)
      @page = page
      @objects = page.objects
      @seen = Set.new
    end

    def required?
      inline_image?(@page) || images_in_resources?(@page.attributes[:Resources])
    end

    private

    def inline_image?(content)
      probe = InlineImageProbe.new
      content.walk(probe)
      probe.found
    end

    def images_in_resources?(reference)
      dictionary = @objects.deref_hash(reference) || {}
      return false unless @seen.add?(dictionary.object_id)

      entries(dictionary, :XObject).any? { |entry| image_stream?(entry) } ||
        entries(dictionary, :Pattern).any? { |entry| image_stream?(entry) } ||
        entries(dictionary, :Font).any? { |entry| type_three_images?(entry) } ||
        entries(dictionary, :ExtGState).any? { |entry| soft_mask_image?(entry) }
    end

    def entries(dictionary, key)
      (@objects.deref_hash(dictionary[key]) || {}).values
    end

    def type_three_images?(reference)
      font = @objects.deref_hash(reference)
      font && font[:Subtype] == :Type3 &&
        (images_in_resources?(font[:Resources]) || entries(font, :CharProcs).any? { |entry| image_stream?(entry) })
    end

    def soft_mask_image?(reference)
      state = @objects.deref_hash(reference)
      mask = @objects.deref(state&.[](:SMask))
      mask.is_a?(Hash) && image_stream?(mask[:G])
    end

    def image_stream?(reference)
      stream = @objects.deref(reference)
      return false unless stream.is_a?(PDF::Reader::Stream) && @seen.add?(stream.object_id)
      return true if stream.hash[:Subtype] == :Image

      inline_image?(PDF::Reader::FormXObject.new(@page, stream)) || images_in_resources?(stream.hash[:Resources])
    end
  end
end
