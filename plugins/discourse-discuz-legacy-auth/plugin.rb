# frozen_string_literal: true

# name: discourse-discuz-legacy-auth
# about: Migrates imported Discuz credentials on the user's first successful login.
# version: 0.1.0
# authors: SinoFSX

module ::DiscourseDiscuzLegacyAuth
  PLUGIN_NAME = "discourse-discuz-legacy-auth"
end

gem "bcrypt", "3.1.22"

after_initialize do
  require_relative "lib/discourse_discuz_legacy_auth/legacy_credentials"
  require_relative "lib/discourse_discuz_legacy_auth/session_controller_extension"
  require_relative "lib/discourse_discuz_legacy_auth/user_password_extension"
  require_relative "lib/discourse_discuz_legacy_auth/user_avatar_extension"
  require_relative "lib/discourse_discuz_legacy_auth/basic_user_serializer_avatar_extension"

  ::SessionController.include(::DiscourseDiscuzLegacyAuth::LegacyCredentials)
  ::SessionController.include(::DiscourseDiscuzLegacyAuth::SessionControllerExtension)
  ::UserPassword.include(::DiscourseDiscuzLegacyAuth::UserPasswordExtension)
  ::User.prepend(::DiscourseDiscuzLegacyAuth::UserAvatarExtension)
  ::BasicUserSerializer.prepend(::DiscourseDiscuzLegacyAuth::BasicUserSerializerAvatarExtension)
end
