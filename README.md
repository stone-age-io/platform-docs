# platform-docs

The authorization model documented here — `docs/authorization.md` and every page that references it — must track `platform/CLAUDE.md` §Roles & Authorization and the API rules in `platform/schema.json`, which are the only enforcement layer in the platform.

The pages are published to pb-wiki. Each file starts with frontmatter giving its wiki `path` and `nav_order` (the top `platform` page also sets `access: public`, which the others inherit), callouts use `::: note Title` … `:::`, and links between pages stay relative `.md` links, which the importer rewrites. Publish with `pb-wiki import docs/`; re-running it updates pages in place.
