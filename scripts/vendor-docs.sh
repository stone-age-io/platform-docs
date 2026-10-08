#!/usr/bin/env bash
# Copy the agent, rule-router and helpdesk repository docs into docs/vendor/
# as wiki pages, each under its own top-level wiki section.
#
#   scripts/vendor-docs.sh [agent-checkout] [rule-router-checkout] [helpdesk-checkout]
#
# The checkouts default to ../agent, ../rule-router and ../helpdesk beside this
# repo. The
# script replaces docs/vendor/<repo>/ completely, so a page deleted upstream
# goes away here too. Files keep their repository layout, which keeps the
# docs' own relative links working; `pb-wiki import` turns them into wiki
# links. Do not edit the copies: change the docs upstream, then run this again.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
agent_src=${1:-$here/../agent}
rr_src=${2:-$here/../rule-router}
hd_src=${3:-$here/../helpdesk}

# repo -> "checkout|GitHub repo"
source_of() {
  case $1 in
    agent) echo "$agent_src|stone-age-io/agent" ;;
    rule-router) echo "$rr_src|skeeeon/rule-router" ;;
    helpdesk) echo "$hd_src|stone-age-io/helpdesk" ;;
  esac
}

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
helpdesk|$hd_src|stone-age-io/helpdesk|README.md|helpdesk|40|access: public
helpdesk|$hd_src|stone-age-io/helpdesk|docs/overview.md|helpdesk/overview|10|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/data-model.md|helpdesk/data-model|20|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/protocol.md|helpdesk/protocol|30|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/notifications.md|helpdesk/notifications|40|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/email-ingestion.md|helpdesk/email-ingestion|50|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/configuration.md|helpdesk/configuration|60|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/plan.md|helpdesk/plan|70|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/service-delivery-plan.md|helpdesk/service-delivery-plan|80|
helpdesk|$hd_src|stone-age-io/helpdesk|docs/nats-notifications-plan.md|helpdesk/nats-notifications-plan|90|
EOF
}

# Start each repo's copy from empty, and note which commit it came from.
for repo in agent rule-router helpdesk; do
  IFS='|' read -r src gh <<<"$(source_of "$repo")"
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
    # heading. Only a link to another vendored page becomes a wiki link, so a
    # relative link to any other repo file (LICENSE, an example rule, a .md
    # that is not vendored) points at GitHub instead.
    # GitHub keeps a double hyphen in an anchor where a heading had " & "
    # or " / " (#requestreply--responses); pb-wiki's heading ids have one.
    sed -e 's/\r$//' \
        -e '/^<\/\{0,1\}details>$/d' \
        -e 's|^<summary><b>\(.*\)</b></summary>$|### \1|' \
        "$src/$file" |
      GH=$gh DIR=$(dirname "$file") \
      VENDORED=$(pages | awk -F'|' -v r="$repo" '$1 == r { print $4 }') perl -pe '
        BEGIN { %v = map { $_ => 1 } split /\s+/, $ENV{VENDORED} }
        s{\]\((?![a-z]+:|[#/])([^)\s#]+)\)}{
          my $p = $1;
          my @out;
          for (split m{/}, "$ENV{DIR}/$p") {
            next if $_ eq "" || $_ eq ".";
            $_ eq ".." ? pop @out : push @out, $_;
          }
          my $r = join("/", @out);
          $v{$r} ? "]($p)" : "](https://github.com/$ENV{GH}/blob/main/$r)";
        }ge;
        s{\]\(([^)\s#]*)#([^)\s]+)\)}{my ($p, $a) = ($1, $2); $a =~ s/-{2,}/-/g; "]($p#$a)"}ge'
  } > "$dest"
done

echo "vendored into docs/vendor/:"
cat "$here"/docs/vendor/*/SOURCE
