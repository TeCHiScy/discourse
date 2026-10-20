# frozen_string_literal: true

# name: discourse-discuz-legacy-auth
# about: Supports imported Discuz accounts and profile rendering.
# version: 0.1.0
# authors: SinoFSX

register_asset "stylesheets/common/discuz-user-signature.scss"

module ::DiscourseDiscuzLegacyAuth
  PLUGIN_NAME = "discourse-discuz-legacy-auth"
end

gem "bcrypt", "3.1.22"

after_initialize do
  register_user_custom_field_type("discuz_signature_html", :string, max_length: 20_000)
  allow_public_user_custom_field("discuz_signature_html")
  register_post_custom_field_type("discuz_usesig", :boolean)
  register_post_custom_field_type("discuz_anonymous", :boolean)
  topic_view_post_custom_fields_allowlister { |_user, _topic| %w[discuz_usesig discuz_anonymous] }

  require_relative "lib/discourse_discuz_legacy_auth/legacy_credentials"
  require_relative "lib/discourse_discuz_legacy_auth/session_controller_extension"
  require_relative "lib/discourse_discuz_legacy_auth/user_password_extension"
  require_relative "lib/discourse_discuz_legacy_auth/user_avatar_extension"
  require_relative "lib/discourse_discuz_legacy_auth/basic_user_serializer_avatar_extension"

  add_to_serializer(:user_card, :bio_excerpt) do
    fields = object.custom_fields
    imported_discuz_user =
      fields["discuz_source"] == "discuz_x3.5" && fields["discuz_uid"].present? &&
        fields["import_id"].to_s == fields["discuz_uid"].to_s

    object.user_profile.bio_excerpt(
      350,
      keep_newlines: true,
      keep_emoji_images: true,
      keep_images: imported_discuz_user,
    )
  end

  add_to_serializer(
    :post,
    :discuz_signature_enabled,
    include_condition:
      lambda do
        post_custom_fields.key?("discuz_usesig") || post_custom_fields.key?("discuz_anonymous")
      end,
  ) do
    fields = post_custom_fields
    fields["discuz_usesig"] != false && fields["discuz_anonymous"] != true
  end

  ::SessionController.include(::DiscourseDiscuzLegacyAuth::LegacyCredentials)
  ::SessionController.include(::DiscourseDiscuzLegacyAuth::SessionControllerExtension)
  ::UserPassword.include(::DiscourseDiscuzLegacyAuth::UserPasswordExtension)
  ::User.prepend(::DiscourseDiscuzLegacyAuth::UserAvatarExtension)
  ::BasicUserSerializer.prepend(::DiscourseDiscuzLegacyAuth::BasicUserSerializerAvatarExtension)
end
