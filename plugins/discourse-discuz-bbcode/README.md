# Discuz table BBCode for Discourse

This plugin renders Discuz [table], [tr], and [td] markup when Discourse cooks posts. It keeps the original BBCode in posts.raw and produces sanitized table HTML in the derived cooked body.

Supported table content:

- Explicit rows and cells, including [td=colspan,rowspan,width].
- Legacy line-and-pipe tables, with \| treated as a literal pipe.
- Inline Markdown and BBCode supported by Discourse inside cells.

Discuz width and background-color values are discarded. The output retains cell spans and uses Discourse's md-table wrapper. Invalid or unsupported table structure stays as readable source text instead of being partially rewritten.

The feature is controlled by discourse_discuz_bbcode_tables_enabled. After changing the setting or installing the plugin, rebake matching posts so their cooked bodies are regenerated from the unchanged raw source.
