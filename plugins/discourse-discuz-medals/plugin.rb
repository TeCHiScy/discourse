# frozen_string_literal: true

# name: discourse-discuz-medals
# about: Imports Discuz X medals as native Discourse badges.
# version: 0.1.0
# authors: SinoFSX

after_initialize do
  require_relative "app/models/discourse_discuz_medals/medal_mapping"
  require_relative "app/models/discourse_discuz_medals/user_medal_grant"
  require_relative "app/jobs/scheduled/discourse_discuz_medals/expire_grants"
  require_relative "lib/discourse_discuz_medals/badge_image_url_extension"

  ::Badge.prepend(::DiscourseDiscuzMedals::BadgeImageUrlExtension)
end
