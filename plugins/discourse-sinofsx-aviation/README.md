# Discourse SinoFSX Aviation

This plugin is the Discourse-side home for the Discuz `sino_flydata` and
`sinofsx` adaptations. The first slice exposes the public flight-data fields
used by Discuz post profiles in Discourse user cards:

- callsign, including the effective airline prefix;
- virtual-airline name;
- ATC rank;
- pilot and ATC hours.

The planned importer will populate these public user custom fields after the
source snapshot includes `extend_flydata`. This plugin does not connect to
Discuz MySQL at runtime.

The first callsign-exam slice adds a logged-in-user modal and server-side
question/attempt tables. An importer still needs to populate the question bank
from a sanitized snapshot; the exam stays disabled by default until then. A
legacy callsign already imported to the user's `sinofsx_callsign` custom field
counts as passed, matching the Discuz rule for existing pilots.

The remaining port is staged separately: FSD account registration/password
updates, event dispatch-seat signup, and virtual-airline membership,
applications, prefix changes, and manager actions. External FSD API writes
must remain disabled in local rehearsal until an explicit API configuration
and safe test account are available.

The local migration baseline currently contains only the BBS and UCenter
schemas; it does not include `extend_flydata` or `extend_systems`. No source
questions, callsigns, memberships, or FSD passwords are synthesized by this
plugin.
