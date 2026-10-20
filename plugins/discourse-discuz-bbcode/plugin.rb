# frozen_string_literal: true

# name: discourse-discuz-bbcode
# about: Renders Discuz X table BBCode in Discourse posts.
# version: 0.1.0
# authors: SinoFSX

enabled_site_setting :discourse_discuz_bbcode_tables_enabled
enabled_site_setting :discourse_discuz_bbcode_attachments_enabled
enabled_site_setting :discourse_discuz_bbcode_sell_enabled

register_asset "stylesheets/common/discuz-attachments.scss"

Discourse::Application.routes.prepend do
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
  get "/discuz-posts/:post_id/attachments",
      to: "discourse_discuz_bbcode/attachments#list",
      constraints: {
        post_id: /\d+/,
      }
  get "/discuz-sell-sections/:pid/:cid",
      to: "discourse_discuz_bbcode/sell_sections#show",
      constraints: {
        pid: /\d+/,
        cid: /\d+/,
      }
  post "/discuz-sell-sections/:pid/:cid/purchase",
       to: "discourse_discuz_bbcode/sell_sections#purchase",
       constraints: {
         pid: /\d+/,
         cid: /\d+/,
       }
end

after_initialize do
  require_relative "app/models/discourse_discuz_bbcode/attachment"
  require_relative "app/models/discourse_discuz_bbcode/sell_section"
  require_relative "app/models/discourse_discuz_bbcode/sell_purchase"
  require_relative "app/models/discourse_discuz_bbcode/sell_credit_balance"
  require_relative "app/models/discourse_discuz_bbcode/sell_transaction"
  require_relative "lib/discourse_discuz_bbcode/attachment_signer"
  require_relative "lib/discourse_discuz_bbcode/sell_tag_parser"
  require_relative "lib/discourse_discuz_bbcode/sell_access"
  require_relative "lib/discourse_discuz_bbcode/sell_purchase_service"
  require_relative "app/controllers/discourse_discuz_bbcode/attachments_controller"
  require_relative "app/controllers/discourse_discuz_bbcode/sell_sections_controller"
end
