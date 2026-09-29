# platform-docs

The authorization model documented here — `docs/authorization.md` and every page that references it — must track `platform/CLAUDE.md` §Roles & Authorization and the API rules in `platform/schema.json`, which are the only enforcement layer in the platform.

The pages are published to pb-wiki. Each file starts with frontmatter giving its wiki `path` and `nav_order` (the top `platform` page also sets `access: public`, which the others inherit), callouts use `::: note Title` … `:::`, and links between pages stay relative `.md` links, which the importer rewrites. Publish with `pb-wiki import docs/`; re-running it updates pages in place.

`docs/vendor/` holds copies of the [agent](https://github.com/stone-age-io/agent) and [rule-router](https://github.com/skeeeon/rule-router) repository docs, published as the `agent` and `rule-router` wiki sections. Do not edit them here: change the docs upstream, then run `scripts/vendor-docs.sh` (it reads `../agent` and `../rule-router` by default) and commit the result. Each `SOURCE` file records the commit the copies came from.
