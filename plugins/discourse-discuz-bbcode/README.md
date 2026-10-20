# Discuz table BBCode for Discourse

This plugin renders Discuz [table], [tr], and [td] markup when Discourse cooks posts. It keeps the original BBCode in posts.raw and produces sanitized table HTML in the derived cooked body. It also renders `[attach]AID[/attach]` references from imported attachment metadata without copying the COS objects.

Supported table content:

- Explicit rows and cells, including [td=colspan,rowspan,width].
- Legacy line-and-pipe tables, with \| treated as a literal pipe.
- Inline Markdown and BBCode supported by Discourse inside cells.

Discuz width and background-color values are discarded. The output retains cell spans and uses Discourse's md-table wrapper. Invalid or unsupported table structure stays as readable source text instead of being partially rewritten.

Attachment metadata is stored in the `discuz_attachments` table. The client resolves each AID through a same-origin metadata route. Images are rendered inline; other files become download links. The download route checks Discourse post visibility and refuses source-level read restrictions or paid attachments/topics until those rules have a verified Discourse entitlement mapping. It redirects to the existing Discuz `forum.php?mod=attachment` handler, which reads `remote=0` files through Discuz's configured attachment directory (the current server mounts COS there) and handles `remote=1` files with its existing gateway flow. The Discourse process needs `DISCUZ_LEGACY_AUTHKEY` and an HTTPS `DISCUZ_ATTACHMENT_SOURCE_URL` to generate the standard Discuz `aidencode` token; neither value is stored in the database or this repository. In local rehearsal these variables stay unset, so the UI shows safe filename placeholders and does not contact the live BBS. The plugin never falls back to an unsigned COS URL.

The table and attachment renderers are controlled independently by `discourse_discuz_bbcode_tables_enabled` and `discourse_discuz_bbcode_attachments_enabled`. After changing a setting or installing the plugin, rebake matching posts so their cooked bodies are regenerated from the unchanged raw source. Metadata-only imports use `DISCUZX_IMPORT_STAGE=attachment_metadata`; they require the relation-closed sample manifest but do not read local attachment files.
