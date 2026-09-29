#!/usr/bin/env bash
# Copy the agent and rule-router repository docs into docs/vendor/ as wiki
# pages, each under its own top-level wiki section.
#
#   scripts/vendor-docs.sh [agent-checkout] [rule-router-checkout]
#
# The checkouts default to ../agent and ../rule-router beside this repo. The
# script replaces docs/vendor/<repo>/ completely, so a page deleted upstream
# goes away here too. Files keep their repository layout, which keeps the
# docs' own relative links working; `pb-wiki import` turns them into wiki
# links. Do not edit the copies: change the docs upstream, then run this again.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
agent_src=${1:-$here/../agent}
rr_src=${2:-$here/../rule-router}

# repo | checkout | GitHub repo | file | wiki path | nav_order | extra frontmatter
pages() {
cat <<EOF
agent|$agent_src|stone-age-io/agent|README.md|agent|20|access: public
agent|$agent_src|stone-age-io/agent|docs/architecture.md|agent/architecture|10|
agent|$agent_src|stone-age-io/agent|docs/linux.md|agent/linux|20|
agent|$agent_src|stone-age-io/agent|docs/windows.md|agent/windows|30|
agent|$agent_src|stone-age-io/agent|docs/freebsd.md|agent/freebsd|40|
agent|$agent_src|stone-age-io/agent|docs/credentials.md|agent/credentials|50|
agent|$agent_src|stone-age-io/agent|docs/script-development.md|agent/script-development|60|
agent|$agent_src|stone-age-io/agent|docs/nebula.md|agent/nebula|70|
agent|$agent_src|stone-age-io/agent|docs/leaf-node.md|agent/leaf-node|80|
agent|$agent_src|stone-age-io/agent|docs/edge-sync-design.md|agent/edge-sync-design|90|
agent|$agent_src|stone-age-io/agent|docs/nebula-design.md|agent/nebula-design|100|
rule-router|$rr_src|skeeeon/rule-router|README.md|rule-router|30|access: public
rule-router|$rr_src|skeeeon/rule-router|docs/01-core-concepts.md|rule-router/core-concepts|10|
rule-router|$rr_src|skeeeon/rule-router|docs/02-gateway.md|rule-router/gateway|20|
rule-router|$rr_src|skeeeon/rule-router|docs/03-scheduler.md|rule-router/scheduler|30|
rule-router|$rr_src|skeeeon/rule-router|docs/04-system-variables.md|rule-router/system-variables|40|
rule-router|$rr_src|skeeeon/rule-router|docs/05-array-processing.md|rule-router/array-processing|50|
rule-router|$rr_src|skeeeon/rule-router|docs/06-primitive-messages.md|rule-router/primitive-messages|60|
rule-router|$rr_src|skeeeon/rule-router|docs/07-security.md|rule-router/security|70|
rule-router|$rr_src|skeeeon/rule-router|docs/08-kv-rule-store.md|rule-router/kv-rule-store|80|
rule-router|$rr_src|skeeeon/rule-router|docs/09-patterns.md|rule-router/patterns|90|
rule-router|$rr_src|skeeeon/rule-router|docs/10-troubleshooting.md|rule-router/troubleshooting|100|
rule-router|$rr_src|skeeeon/rule-router|docs/11-configuration.md|rule-router/configuration|110|
rule-router|$rr_src|skeeeon/rule-router|docs/12-observability.md|rule-router/observability|120|
rule-router|$rr_src|skeeeon/rule-router|cmd/rule-router/README.md|rule-router/rule-router-binary|130|title: The rule-router Binary
rule-router|$rr_src|skeeeon/rule-router|cmd/rule-cli/README.md|rule-router/rule-cli|140|
rule-router|$rr_src|skeeeon/rule-router|cmd/nats-auth-manager/README.md|rule-router/nats-auth-manager|150|
rule-router|$rr_src|skeeeon/rule-router|web/README.md|rule-router/web-ui|160|
EOF
}

# Start each repo's copy from empty, and note which commit it came from.
for repo in agent rule-router; do
  src=$agent_src; gh=stone-age-io/agent
  [ "$repo" = rule-router ] && { src=$rr_src; gh=skeeeon/rule-router; }
  rm -rf "$here/docs/vendor/$repo"
  mkdir -p "$here/docs/vendor/$repo"
  printf 'https://github.com/%s @ %s\n' "$gh" "$(git -C "$src" rev-parse HEAD)" \
    > "$here/docs/vendor/$repo/SOURCE"
done

pages | while IFS='|' read -r repo src gh file path order extra; do
  dest="$here/docs/vendor/$repo/$file"
  mkdir -p "$(dirname "$dest")"
  {
    printf -- '---\npath: %s\nnav_order: %s\n' "$path" "$order"
    [ -n "$extra" ] && printf '%s\n' "$extra"
    printf -- '---\n'
    # pb-wiki renders no raw HTML, so a <details> block becomes a plain
    # heading, and a link to the repo's LICENSE file points at GitHub.
    # GitHub keeps a double hyphen in an anchor where a heading had " & "
    # or " / " (#requestreply--responses); pb-wiki's heading ids have one.
    sed -e 's/\r$//' \
        -e '/^<\/\{0,1\}details>$/d' \
        -e 's|^<summary><b>\(.*\)</b></summary>$|### \1|' \
        -e "s|](\(\./\)\{0,1\}LICENSE)|](https://github.com/$gh/blob/main/LICENSE)|g" \
        "$src/$file" |
      perl -pe 's{\]\(([^)\s#]*)#([^)\s]+)\)}{my ($p, $a) = ($1, $2); $a =~ s/-{2,}/-/g; "]($p#$a)"}ge'
  } > "$dest"
done

echo "vendored into docs/vendor/:"
cat "$here"/docs/vendor/*/SOURCE
