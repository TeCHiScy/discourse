# frozen_string_literal: true

module ::DiscourseDiscuzLegacyAuth::UserAvatarExtension
  DISCUZ_AVATAR_BASE_URL = "https://uc.sinofsx.org/data/avatar"

  def avatar_template
    uid = discuz_avatar_uid
    return super if uid.blank? || uploaded_avatar_id.present?

    padded_uid = uid.rjust(9, "0")
    avatar_path = [padded_uid[0, 3], padded_uid[3, 2], padded_uid[5, 2]]
    filename = "#{padded_uid[-2, 2]}_avatar_small.jpg"
    "#{DISCUZ_AVATAR_BASE_URL}/#{(avatar_path + [filename]).join("/")}"
  end

  private

  def discuz_avatar_uid
    fields = custom_fields
    uid = fields["discuz_uid"].to_s
    return if fields["discuz_source"] != "discuz_x3.5"
    return if uid !~ /\A[1-9][0-9]*\z/ || fields["import_id"].to_s != uid

    uid
  end
end
