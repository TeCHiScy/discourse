# frozen_string_literal: true

require "seed_data/categories"

if Rails.env.test?
  # Tests need the Uncategorized category, but none of the others.
  SeedData::Categories.with_default_locale.create(site_setting_names: ["uncategorized_category_id"])
else
  # This checkout imports an existing Discuz forum; these Discourse-only
  # categories do not belong in the migrated site's initial seed data.
  SeedData::Categories.with_default_locale.create(
    site_setting_names: %w[uncategorized_category_id general_category_id],
  )
end
