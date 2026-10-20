# frozen_string_literal: true

unless defined?(::DiscourseDiscuzLegacyAuth)
  module ::DiscourseDiscuzLegacyAuth
  end
end
require_relative "../../lib/discourse_discuz_legacy_auth/user_avatar_extension"

RSpec.describe User do
  let(:source_uid) { "112867" }
  let(:avatar_status) { "0" }
  let(:user) { Fabricate(:user, username: "discuz_avatar_test") }

  before do
    user.singleton_class.prepend(::DiscourseDiscuzLegacyAuth::UserAvatarExtension)
    user.custom_fields = {
      "discuz_source" => "discuz_x3.5",
      "discuz_uid" => source_uid,
      "discuz_avatarstatus" => avatar_status,
      "import_id" => source_uid,
    }
    user.save_custom_fields
  end

  it "uses the Discourse default avatar when Discuz avatarstatus is zero" do
    expect(user.avatar_template).to eq(
      ::DiscourseDiscuzLegacyAuth::UserAvatarExtension.local_default_avatar_template(user.username),
    )
  end

  it "uses the Discuz avatar URL when avatarstatus is one" do
    user.custom_fields["discuz_avatarstatus"] = "1"
    user.save_custom_fields

    expect(user.avatar_template).to eq(
      "https://uc.sinofsx.org/data/avatar/000/11/28/67_avatar_small.jpg",
    )
  end

  it "keeps an uploaded Discourse avatar ahead of the Discuz URL" do
    user.custom_fields["discuz_avatarstatus"] = "1"
    user.save_custom_fields
    upload = Fabricate(:upload, user: user)
    user.update!(uploaded_avatar_id: upload.id)

    expect(user.avatar_template).to eq(User.avatar_template(user.username, upload.id))
    expect(user.avatar_template).not_to start_with(
      ::DiscourseDiscuzLegacyAuth::UserAvatarExtension::DISCUZ_AVATAR_BASE_URL,
    )
  end

  it "uses the Discourse default when the imported avatar marker is absent" do
    user.custom_fields.delete("discuz_avatarstatus")
    user.save_custom_fields

    expect(user.avatar_template).to eq(
      ::DiscourseDiscuzLegacyAuth::UserAvatarExtension.local_default_avatar_template(user.username),
    )
  end
end
