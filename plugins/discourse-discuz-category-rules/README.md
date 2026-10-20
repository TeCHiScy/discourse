# discourse-discuz-category-rules

Stores Discuz forum rules in the `discuz_rules` category custom field, exposes
an editor in category settings, and renders sanitized Markdown below the
category heading. The Discuz importer stores the short forum description in
Discourse's native `Category.description` and marks categories to skip the
automatic category-definition topic.

The importer sets the core `skip_category_definition` marker before saving a
category, so Discourse does not create an “About this category” topic. On a
category-stage rerun, an existing generated definition topic is trashed only
when it is system-authored, has no replies, and retains Discourse's generated
title; its `topic_id` is then cleared.
