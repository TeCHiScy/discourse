# Discuz medals for Discourse

The importer maps Discuz medal definitions to native Discourse badges and current
user awards to native `UserBadge` records. Discourse then renders awards on user
profiles and, when enabled, beside their posts.

The importer keeps the Discuz medal ID, source name, description, image
reference, availability, owner UID, and expiration metadata in plugin tables.
Medal images link to `https://static.sinofsx.org/image/common/`; both a filename
and a full URL on that host are accepted. Image files remain on the Discuz static
host, so the links depend on that host remaining available.
The importer reconciles only imported Discuz-owned awards; rerunning the medal
stage adds new awards, removes expired/revoked awards, and updates definitions.
Unrelated native badges and user awards are not touched. Historical awards are
written without sending notifications or firing badge-granted events; native
badge counts and user badge ranks are recalculated after the sync.
Future-dated expirations are removed by a daily scheduled job, matching the
Discuz daily medal expiry behavior.

Run the plugin's database migrations against the isolated sample target, then
run `DISCUZX_IMPORT_STAGE=medals` with the relation-closed sample manifest after
the sample identity stage. Finish with `verify_import.rb --sample-medals`. The
standalone stage imports only medal definitions and awards for manifest
`member_uids`; it does not import users, categories, posts, or messages. The
full `all` importer includes medals after its ordinary content import.

Discuz's self-claim workflow and ongoing award automation are not migrated.
The imported current state is reconciled whenever the medal stage is rerun.
