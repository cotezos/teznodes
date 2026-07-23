#!/usr/bin/env bash
# Regenerate the marker-delimited `sites:` block of .upptimerc.yml from the
# public Tezos node sources.
#
# Each source is fetched and normalized INDEPENDENTLY: a failure in one
# (endpoint unavailable, upstream format change) must NOT drop the entries
# contributed by the others — it just degrades to an empty list for that
# source. The script only fails, leaving .upptimerc.yml untouched, when the
# merged result is suspiciously small (all or most sources empty).
#
# Sources, in deduplication precedence order (first occurrence of a host wins):
#   1. teztnets.com/teztnets.json        — test networks, freshest for teztnets hosts
#   2. taquito rpc_nodes.json            — community RPC endpoints (taquito.io, repo fallback)
#   3. tezos-facts merged_prometheus_sd  — Nomadic Labs aggregator of the above plus
#                                          docs.tezos.com; also our only docs-derived source
#
# All normalizers converge on the same site name for the same host
# ("<network> [<provider>] (https://<host>)"), so Upptime history is stable
# regardless of which source happens to win the dedup.
set -u
cd "$(dirname "$0")/.." || exit 1

TEZTNETS_JSON_URL=${TEZTNETS_JSON_URL:-https://teztnets.com/teztnets.json}
TAQUITO_RPC_NODES_URL=${TAQUITO_RPC_NODES_URL:-https://taquito.io/rpc_nodes.json}
# Byte-identical file straight from the taquito source repo (stable,
# unversioned path), used only if taquito.io is unreachable.
TAQUITO_RPC_NODES_FALLBACK_URL=${TAQUITO_RPC_NODES_FALLBACK_URL:-https://raw.githubusercontent.com/ecadlabs/taquito/main/website/public/rpc_nodes.json}
TEZOS_FACTS_MERGED_SD_URL=${TEZOS_FACTS_MERGED_SD_URL:-https://tezos-infra.gitlab.io/vigies/tezos-facts/merged_prometheus_sd.json}

MIN_SITES=${MIN_SITES:-3}

BEGIN_MARKER='# BEGIN sites managed by update_upptimerc.yml'
END_MARKER='# END sites managed by update_upptimerc.yml'

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

warn()  { echo "WARNING: $*" >&2; }
fetch() { curl -fsS --retry 2 --retry-delay 5 --max-time 60 "$1" -o "$2"; }

# normalize <label> <raw-file> <jq-program> <out-file>
# Produces a JSON array of {key, name, url} entries; falls back to [] so the
# merge never aborts on one bad source.
normalize() {
  local label=$1 raw=$2 program=$3 out=$4
  if [ -s "$raw" ] && jq "$program" "$raw" > "$out" 2>/dev/null; then
    echo "OK: $label ($(jq length "$out") sites)"
  else
    warn "$label failed — contributing no sites this run"
    echo "[]" > "$out"
  fi
}

# --- teztnets.com --------------------------------------------------------
# - Weeklynet ("Periodic/Internal Teztnets") is excluded: its hostname
#   rotates every week, which would reset Upptime history and open a
#   down-incident at each rotation.
# - Alias entries (key != lowercased human_name, e.g. "currentnet" for
#   Ushuaianet) are excluded: they duplicate the canonical network under a
#   redirecting hostname.
# - teztnets.com is Tezos Foundation infrastructure: hardcoding the
#   tezosfoundation provider matches the taquito naming for the same hosts.
fetch "$TEZTNETS_JSON_URL" "$WORKDIR/teztnets.json" || warn "teztnets fetch failed"
normalize teztnets "$WORKDIR/teztnets.json" '
  [ to_entries[]
    | select(.value.rpc_url)
    | select(.value.category != "Periodic/Internal Teztnets")
    | select(.key == (.value.human_name | ascii_downcase))
    | { key:  (.value.rpc_url | sub("^https?://"; "") | sub("/$"; "")),
        name: "\(.key) [tezosfoundation] (\(.value.rpc_url))",
        url:  "\(.value.rpc_url)/chains/main/blocks/head/header" }
  ]' "$WORKDIR/teztnets_sites.json"

# --- taquito rpc_nodes.json ----------------------------------------------
fetch "$TAQUITO_RPC_NODES_URL" "$WORKDIR/rpc_nodes.json" \
  || { warn "taquito.io unreachable — trying repo fallback"; \
       fetch "$TAQUITO_RPC_NODES_FALLBACK_URL" "$WORKDIR/rpc_nodes.json" \
         || warn "taquito fetch failed (contract + repo fallback)"; }
normalize taquito "$WORKDIR/rpc_nodes.json" '
  [ .rpc_endpoints[]
    | select(.net and .url and .provider)
    | { key:  (.url | sub("^https?://"; "") | sub("/$"; "")),
        name: "\(.net) [\(.provider)] (\(.url))",
        url:  "\(.url)/chains/main/blocks/head/header" }
  ]' "$WORKDIR/taquito_sites.json"

# --- tezos-facts merged service-discovery --------------------------------
# Aggregates teztnets + taquito + docs.tezos.com; mostly redundant with the
# direct sources above (dedup handles that) but the only one contributing
# the docs.tezos.com-derived nodes. teztnets-sourced entries carry no
# provider label — same tezosfoundation default as the direct source.
fetch "$TEZOS_FACTS_MERGED_SD_URL" "$WORKDIR/tezos_facts.json" || warn "tezos-facts fetch failed"
normalize tezos-facts "$WORKDIR/tezos_facts.json" '
  [ .[]
    | select(.labels.category != "Periodic/Internal Teztnets")
    | (.labels.provider // "tezosfoundation") as $provider
    | .labels.tezos_network as $network
    | .targets[]
    | { key:  .,
        name: "\($network) [\($provider)] (https://\(.))",
        url:  "https://\(.)/chains/main/blocks/head/header" }
  ]' "$WORKDIR/tezos_facts_sites.json"

# --- merge: dedup by host, precedence = argument order --------------------
jq -rs '
  add
  | reduce .[] as $e ({out: [], seen: {}};
      if .seen[$e.key] then .
      else {out: (.out + [$e]), seen: (.seen + {($e.key): true})} end)
  | .out
  | sort_by(.name)
  | .[]
  | "- name: \(.name)\n  url: \(.url)"
' "$WORKDIR/teztnets_sites.json" "$WORKDIR/taquito_sites.json" \
  "$WORKDIR/tezos_facts_sites.json" > "$WORKDIR/new_sites.txt"

SITE_COUNT=$(grep -c '^- name: ' "$WORKDIR/new_sites.txt" || true)
echo "Merged: $SITE_COUNT sites"
# Refuse to shrink the list to (near-)nothing: broken upstream feeds must
# not wipe the monitored sites.
if [ "$SITE_COUNT" -lt "$MIN_SITES" ]; then
  echo "ERROR: only $SITE_COUNT sites merged (< $MIN_SITES) — keeping the existing list" >&2
  exit 1
fi

# --- splice between the markers -------------------------------------------
if ! grep -qF "$BEGIN_MARKER" .upptimerc.yml || ! grep -qF "$END_MARKER" .upptimerc.yml; then
  echo "ERROR: markers not found in .upptimerc.yml" >&2
  exit 1
fi
awk -v sites="$WORKDIR/new_sites.txt" -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
  index($0, begin) {
    print
    while ((getline line < sites) > 0) print line
    skip = 1
    next
  }
  index($0, end) { skip = 0 }
  !skip { print }
' .upptimerc.yml > "$WORKDIR/upptimerc.new"

# --- validate before replacing --------------------------------------------
SITES_IN_CONFIG=$(yq e '.sites | length' "$WORKDIR/upptimerc.new")
echo "sites in config: $SITES_IN_CONFIG (merged: $SITE_COUNT)"
if [ "$SITES_IN_CONFIG" != "$SITE_COUNT" ]; then
  echo "ERROR: spliced YAML site count mismatch — keeping the existing list" >&2
  exit 1
fi

mv "$WORKDIR/upptimerc.new" .upptimerc.yml
echo "OK: .upptimerc.yml updated ($SITE_COUNT sites)"
