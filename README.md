# platform-docs

The authorization model documented here — `docs/authorization.md` and every page that references it — must track the role table in `platform/CLAUDE.md` §Roles & Authorization, the rules in `platform/AUTHORIZATION.md`, and the API rules in `platform/schema.json`, which are the only enforcement layer in the platform.

The pages are published to pb-wiki. Each file starts with frontmatter giving its wiki `path` and `nav_order` (the homepage, `home.md` at path `""`, and each top section page set `access: public`, which their children inherit), callouts use `::: note Title` … `:::`, and links between pages stay relative `.md` links, which the importer rewrites. Publish with `pb-wiki import docs/`; re-running it updates pages in place.

`docs/vendor/` holds copies of the [agent](https://github.com/stone-age-io/agent), [rule-router](https://github.com/skeeeon/rule-router), [helpdesk](https://github.com/stone-age-io/helpdesk), [access-control](https://github.com/stone-age-io/access-control) and [services](https://github.com/stone-age-io/services) repository docs, published as the `agent`, `rule-router`, `helpdesk`, `access-control` and `services` wiki sections. Do not edit them here: change the docs upstream, then run `scripts/vendor-docs.sh` (it reads `../agent`, `../rule-router`, `../helpdesk`, `../access-control` and `../services` by default) and commit the result. Each `SOURCE` file records the commit the copies came from.

`docs/operations.md` §6.1 is the one table of the versions these docs describe. Update it in the same commit when you re-vendor, or when a page changes to follow a new release. Do not add a new version number to another page if a link to that table does the job.

`docs/stability.md` lists the surfaces that 1.0 will keep stable. When a change touches one of them (a custom route, a `leaf-config` field, a config key, an Agent subject, a CLI command), update that page and the platform CHANGELOG in the same change.
