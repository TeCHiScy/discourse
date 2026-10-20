# Discuz migration rehearsal checks

validate_snapshot.py validates the local restore of the encrypted bbs + ucenter
baseline. It streams GPG decryption into gzip parsing, counts table definitions and
rows from each INSERT statement, then compares every table name and exact row count
with the isolated local MySQL database. It does not write or print SQL rows.

The script currently points to the one-time baseline at
/Users/daren/discourse-lab/baseline/sinofsx-bbs-ucenter-20261009T215026+0800.sql.gz.gpg.
Pass DUMP_KEY and MYSQL_PWD only as temporary environment values populated by the
approved Bitwarden field reader. Do not put either secret in command arguments, files,
logs, or this repository.

The restored baseline passed with 352/352 tables and 15,130,201/15,130,201 rows.
This check validates the MySQL baseline restore; an importer-level acceptance report
compares Discuz source records with imported Discourse records and reports intentional
omissions or unmapped identities.

## Import rehearsal

`verify_import.rb --source-preflight` reads the local MySQL baseline and checks source
coverage without selecting post or message bodies. Running it without the flag performs
the post-import read-only acceptance checks against the local Discourse development
database. Both scripts reject source/target endpoints outside the pinned loopback lab.
Normal Discuz categories include root rows (type=group) and boards/subboards when
status is 0 or 1. Circle nodes use status=3 and special rows use status=2; both are
excluded. If a source hierarchy exceeds Discourse's configured nesting limit, the importer
places the category under the nearest source ancestor that keeps the target within that
limit; duplicate names are detected against the resulting target hierarchy. Re-running the
category stage reconciles imported names and parent links. Mappings from a prior run whose
source rows are now excluded are kept for review but made staff-only; the importer does not
delete their categories or content.

For non-test database seeds, this migration checkout creates only the required
Uncategorized and temporary General categories. It omits Discourse's default Staff and Site
Feedback categories because they are not part of the imported Discuz forum. The importer
also keeps its guarded cleanup for already-seeded databases, and the acceptance verifier
fails if either default category or its active topics remain after import.

Source categories receive a staff-only read fallback only when the source excludes the Discuz guest group or has an active formula, medal, user-list, or password rule.
Empty serialized formula defaults and allow-lists that include guest group 7 remain
public. Effective post/reply restrictions become public read-only categories. The
acceptance report checks each
category's visibility, permission groups, and boolean source-rule markers. Exact Discuz
group/formula/password and per-user access equivalence remains pending review.

For a relation-closed rehearsal manifest, `DISCUZX_IMPORT_STAGE=categories` reapplies
category mappings and permissions and updates the default sidebar links; it leaves user
identity, post, and message records untouched. `identity` imports users and categories,
while `content` imports posts and private messages. `attachments` converts uploads in
already imported posts without reimporting users, categories, topics, or messages.
All staged modes require `DISCUZX_SAMPLE_MANIFEST` and write only to the database pinned in
that manifest. The sample target allowlist includes a separate UID 18 rehearsal database so
the currently served sample remains intact during reimport.

User identity handling is source-tagged. Each imported account carries the source avatarstatus
as a discuz_avatarstatus field. Users with no custom Discuz avatar use Discourse's default
letter avatar; users with a custom avatar keep the Discuz URL unless a local avatar upload
was imported. Each account also carries
`discuz_source=discuz_x3.5` and its Discuz UID; the legacy password adapter accepts only
accounts whose source marker, UID, and importer `import_id` agree. Discourse validates and
suggests unique usernames. Email conflicts (including Discourse-normalized aliases) are
remapped to a reserved `.invalid` address and flagged, with the source address retained
for legacy account lookup; ambiguous matches are rejected. The importer never merges a
Discuz identity into an existing Discourse account. A target containing old numeric
`import_id` rows without matching source tags is rejected before import; use a clean
migration database for that rehearsal.

On an identity-stage rerun, Discourse's base importer skips users whose `import_id`
already exists. This importer still reconciles activation from Discuz `emailstatus`
for those existing accounts: verified, directly mapped addresses are activated and
confirmed idempotently, while duplicate/conflict remaps remain unconfirmed. The
acceptance verifier checks that imported Discuz members are active and that source-
verified, directly mapped email addresses are confirmed.

Before any import stage writes Discuz data, the importer enables and verifies the
site-wide `zh_CN` default locale and Unicode usernames. It then removes
unchanged Discourse seed topics for guidelines, welcome, and the admin quick-start guide;
topics with user replies or staff edits are preserved. It also removes the untouched,
unimported `General` seed category only when it has no active topics or children and its
category definition remains system-authored. Imported or edited categories and categories
with content are preserved. `Uncategorized` remains. The acceptance report checks locale, Unicode usernames, remaining
seed topics, residual unimported `General` categories, dangling default category settings, and
exact sidebar coverage of imported categories, in addition to imported identities and content.
It also fails if either untouched `Site Feedback` or `Staff` category remains.

After category import and seed cleanup, the importer sets Discourse's existing
`default_navigation_menu_categories` site setting to all imported Discuz categories.
This puts accessible categories directly in the sidebar's Categories section for
anonymous and signed-in users; Discourse still filters links using each viewer's category
permissions. The Categories section starts expanded by default in Discourse. Users can
collapse it in their own sidebar, and that preference is stored by the browser.

Attachment conversion follows Discuz's explicit `[attach]aid[/attach]` behavior:
image attachments become inline Discourse uploads, while other files become download
links. Attachments without an explicit inline tag are appended to the post as links or
images. When a snapshot file is missing, the importer keeps the original tag and reports
the failed attachment instead of silently deleting the reference. This still requires
capturing the actual attachment files into the local snapshot before enabling
`DISCUZX_IMPORT_ATTACHMENTS=1`.

After the ordinary sample import, attachment conversion can run by itself with
`DISCUZX_IMPORT_STAGE=attachments` and `DISCUZX_IMPORT_ATTACHMENTS=1`. To rehearse only
specific source attachment IDs, set `DISCUZX_ATTACHMENT_IDS` to a comma-separated list;
this limits replacements to those IDs and leaves other Discuz attachment tags unchanged.
The stage checks the selected source records and local files, including file sizes, before
it writes uploads. It still requires `DISCUZX_SAMPLE_MANIFEST` and the same isolated sample
database.

For COS-resident objects, use `DISCUZX_IMPORT_STAGE=attachment_metadata`. This stage writes
only attachment metadata and AID relationships, keeps `[attach]AID[/attach]` in post bodies,
and does not read or copy blobs. Run `verify_import.rb --sample-attachments` to reconcile
source/target AIDs, object keys, metadata, post relationships, and source references. In the
current stable Discuz code, `remote=0` is served from the configured attachment directory;
the server's `/data/attachment` path is an s3fs mount of COS. Discourse therefore delegates
delivery to the existing `forum.php?mod=attachment` handler using its standard `aidencode`
token. The handler retains Discuz checks and chooses local-mount streaming or its existing
remote gateway path. Object availability and live handler delivery remain separate checks.

## Discuz medals

Discuz's current visible medal state comes from the tab-separated
`common_member_field_forum.medals` value. Each token is a medal ID with an
optional expiration epoch. The importer includes only unexpired assignments
whose `forum_medal` definition is available, matching Discuz's profile and
post-profile rendering. `forum_medallog` supplies the latest award time for
normal and self-claimed awards; if no grant log exists, the importer uses the
imported account creation time and reports that fallback count.

Available and unavailable medal definitions are mapped to native Discourse
badges with source metadata and image references kept in plugin tables. The
first version uses a certificate icon; it does not fetch or upload medal image
files. Current awards become native `UserBadge` rows, visible on user profiles
and next to posts. Re-running the sync reconciles imported grants and removes
expired or revoked source awards without modifying unrelated native badges.
Future-dated expirations are removed daily by a scheduled job. Historical
imports do not send notifications or fire badge-granted events.

For a relation-closed sample, import users first, then run the isolated medal
stage and its read-only verifier:

```sh
DISCUZX_IMPORT_STAGE=medals rbenv exec ruby script/import_scripts/discuz_x.rb
rbenv exec ruby tools/discuz_migration/verify_import.rb --sample-medals
```

The `medals` stage requires `DISCUZX_SAMPLE_MANIFEST`, the same loopback source
snapshot and isolated target database as the other sample stages. It imports
only medal definitions and awards for manifest `member_uids`; it leaves users,
categories, topics, posts, and private messages untouched. The full `all`
stage also includes medals after content import. Discuz self-claim workflows
and ongoing award automation remain outside this first version.

UCenter's source login supports PHP `password_verify` hashes (bcrypt in the current
snapshot) when salt is empty, and the legacy MD5 formula when salt has six characters.
The Discourse plugin uses bcrypt for the PHP hashes and constant-time comparison for the
legacy MD5 hashes. The verifier reports hash-format counts and fails on unsupported or
mismatched formats without returning hash or salt values.

The importer requires the locally installed `mysql2` gem and `php-serialize` for Discuz
PHP-serialized category metadata. The rbenv 3.4.7 environment has `mysql2` 0.5.7 and
`php-serialize` 1.4.1; the latter was installed only in this gemset and did not change
the Discourse Gemfile or lockfile. The `miro` gem is loaded only when importing category
icon files. Do not enable attachment imports until a read-only local file snapshot has
been captured and validated.

Example setup (run from the Discourse checkout; no secret values belong in this file):

```sh
set -a
source /Users/daren/discourse-lab/infra/.env
set +a
export RBENV_VERSION=3.4.7
export DISCUZX_DB_HOST=127.0.0.1 DISCUZX_DB_PORT=13306
export DISCUZX_DB=bbs UCENTER_DB=ucenter DISCUZX_TABLE_PREFIX=
export DISCUZX_DB_USER=root
export MYSQL_PWD="$(/Users/daren/.agents/skills/bitwarden/scripts/read_item_field.sh <local-baseline-item-id> login password)"

rbenv exec ruby tools/discuz_migration/verify_import.rb --source-preflight
rbenv exec ruby script/import_scripts/discuz_x.rb
rbenv exec ruby tools/discuz_migration/verify_import.rb
```

The Bitwarden item must be `Discourse Lab MySQL (SinoFSX Baseline)`, never the
production `MySQL (SinoFSX)` item. The source MySQL session is read-only. The importer
accepts only `127.0.0.1:13306` (`bbs`/`ucenter`) and writes only to
`127.0.0.1:15432` (`discourse_development`). The acceptance verifier is read-only on
both databases and never prints passwords, password hashes, emails, or message bodies.

BBCode-to-Markdown conversion is optional in Discourse's upstream importer and its gem
is not installed in this lab yet; this rehearsal currently runs without that optional
converter. Review rendered content before deciding whether to add it to the local tool
environment.

Discuz forum descriptions are cooked into Discourse's native `Category.description`; forum
rules are stored in the `discuz_rules` category custom field and edited/rendered by the
`discourse-discuz-category-rules` plugin. The importer sets Discourse's
`skip_category_definition` marker before category creation, preventing the automatic
“About this category” topic. On reconciliation it trashes only an unreplied,
system-authored definition topic that still has its generated title. The acceptance
report checks description/rules presence, the skip marker, and that imported categories
have no linked definition topic.

Discuz category imports require `max_category_nesting=3` (a root category plus two
subcategory levels). The importer sets this before calculating category parents; the
acceptance verifier checks the setting and expected hierarchy.
