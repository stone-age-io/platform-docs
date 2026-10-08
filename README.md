# platform-docs

The authorization model documented here — `docs/authorization.md` and every page that references it — must track `platform/CLAUDE.md` §Roles & Authorization and the API rules in `platform/schema.json`, which are the only enforcement layer in the platform.

The pages are published to pb-wiki. Each file starts with frontmatter giving its wiki `path` and `nav_order` (the homepage, `home.md` at path `""`, and each top section page set `access: public`, which their children inherit), callouts use `::: note Title` … `:::`, and links between pages stay relative `.md` links, which the importer rewrites. Publish with `pb-wiki import docs/`; re-running it updates pages in place.

`docs/vendor/` holds copies of the [agent](https://github.com/stone-age-io/agent), [rule-router](https://github.com/skeeeon/rule-router), [helpdesk](https://github.com/stone-age-io/helpdesk) and [access-control](https://github.com/stone-age-io/access-control) repository docs, published as the `agent`, `rule-router`, `helpdesk` and `access-control` wiki sections. Do not edit them here: change the docs upstream, then run `scripts/vendor-docs.sh` (it reads `../agent`, `../rule-router`, `../helpdesk` and `../access-control` by default) and commit the result. Each `SOURCE` file records the commit the copies came from.
