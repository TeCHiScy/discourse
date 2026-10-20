# frozen_string_literal: true

module ::DiscourseDiscuzMedals::BadgeImageUrlExtension
  IMAGE_BASE_URL = "https://static.sinofsx.org/image/common/"
  IMAGE_FILENAME = /\A[a-z0-9][a-z0-9_.-]*\.(?:gif|png|jpe?g|webp)\z/i
  STATIC_IMAGE_URL =
    %r{\Ahttps?://static\.sinofsx\.org/image/common/([a-z0-9][a-z0-9_.-]*\.(?:gif|png|jpe?g|webp))\z}i

  def self.prepended(base)
    base.has_one :discuz_medal_mapping,
                 class_name: "DiscourseDiscuzMedals::MedalMapping",
                 foreign_key: :badge_id,
                 inverse_of: :badge
  end

  def image_url
    return super if image_upload_id.present?

    discuz_medal_image_url || super
  end

  private

  def discuz_medal_image_url
    source_image = discuz_medal_mapping&.source_image.to_s.strip
    return if source_image.blank?

    filename = source_image.match(STATIC_IMAGE_URL)&.[](1) || source_image
    return unless IMAGE_FILENAME.match?(filename)

    "#{IMAGE_BASE_URL}#{filename}"
  end
end
