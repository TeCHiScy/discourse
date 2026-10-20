# frozen_string_literal: true

# name: discourse-discuz-bbcode
# about: Renders Discuz X table BBCode in Discourse posts.
# version: 0.1.0
# authors: SinoFSX

enabled_site_setting :discourse_discuz_bbcode_tables_enabled
enabled_site_setting :discourse_discuz_bbcode_attachments_enabled

register_asset "stylesheets/common/discuz-attachments.scss"

Discourse::Application.routes.append do
  get "/discuz-attachments/:aid/metadata",
      to: "discourse_discuz_bbcode/attachments#metadata",
      constraints: {
        aid: /\d+/,
      }
  get "/discuz-attachments/:aid",
      to: "discourse_discuz_bbcode/attachments#show",
      constraints: {
        aid: /\d+/,
      }
end

after_initialize do
  require_relative "app/models/discourse_discuz_bbcode/attachment"
  require_relative "lib/discourse_discuz_bbcode/attachment_signer"
  require_relative "app/controllers/discourse_discuz_bbcode/attachments_controller"
end
