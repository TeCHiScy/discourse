# frozen_string_literal: true

module ::DiscourseDiscuzLegacyAuth::BasicUserSerializerAvatarExtension
  def avatar_template
    serialized_user = user
    return serialized_user.avatar_template if serialized_user.is_a?(User)

    super
  end
end
