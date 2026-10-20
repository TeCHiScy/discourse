# frozen_string_literal: true

# name: discourse-discuz-category-rules
# about: Stores and displays imported Discuz category rules without definition topics.
# version: 0.1.0
# authors: SinoFSX

register_asset "stylesheets/common/discuz-category-rules.scss"

module ::DiscourseDiscuzCategoryRules
  RULES_CUSTOM_FIELD = "discuz_rules"
end

after_initialize do
  register_category_custom_field_type(DiscourseDiscuzCategoryRules::RULES_CUSTOM_FIELD, :string)
  register_preloaded_category_custom_fields(DiscourseDiscuzCategoryRules::RULES_CUSTOM_FIELD)

  add_to_serializer(:basic_category, :discuz_rules_html) do
    rules = object.custom_fields[DiscourseDiscuzCategoryRules::RULES_CUSTOM_FIELD]
    PrettyText.cook(rules) if rules.present?
  end
end
