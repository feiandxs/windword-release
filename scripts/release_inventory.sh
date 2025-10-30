#!/usr/bin/env bash
# Summarise GitHub releases and asset sizes for the current repository using gh and jq.

set -euo pipefail

TAG=""
REPO=""
LIMIT=100
JSON_OUTPUT=0

usage() {
  cat <<'EOF'
Usage: release_inventory.sh [options]

Options:
  --tag <tag>        Only inspect a specific release tag
  --repo <owner/repo>
                     Override the repository (defaults to current gh repo)
  --limit <n>        Limit number of releases when listing (default: 100)
  --json             Output raw JSON summary
  -h, --help         Show this help message
EOF
}

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: required command "%s" not found in PATH\n' "$1" >&2
    exit 1
  fi
}

human_size() {
  local bytes=${1:-0}
  awk -v b="$bytes" '
    function human(x) {
      split("B KB MB GB TB PB", u, " ");
      i = 1;
      while (x >= 1024 && i < length(u)) {
        x /= 1024;
        i++;
      }
      return sprintf("%.1f %s", x, u[i]);
    }
    BEGIN {
      if (b < 0) b = 0;
      print human(b + 0);
    }
  '
}

while (($# > 0)); do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { echo "Missing value for --tag" >&2; exit 1; }
      TAG="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "Missing value for --repo" >&2; exit 1; }
      REPO="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { echo "Missing value for --limit" >&2; exit 1; }
      LIMIT="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

ensure_command gh
ensure_command jq

TRANSFORM_FILTER=$(cat <<'JQ'
def category($name):
  ($name // "" | ascii_downcase) as $n |
  if ($n | endswith(".exe.blockmap") or endswith(".exe")) then "windows"
  elif ($n | contains("mac") or endswith(".dmg") or endswith(".pkg")) then "macOS"
  elif ($n | contains("linux") or contains("appimage") or endswith(".deb") or endswith(".rpm")) then "linux"
  else "metadata" end;

def assets_list:
  [ (.assets // [])[] | {
      category: category(.name),
      size: (.size // 0 | tonumber),
      downloads: (.downloadCount // 0 | tonumber)
    }];

def cat_summary($assets):
  ($assets
   | group_by(.category)
   | map({key: (.[0].category),
          value: {
            assets: length,
            size: (reduce .[] as $a (0; . + $a.size)),
            downloads: (reduce .[] as $a (0; . + $a.downloads))
          }})
   | from_entries);

assets_list as $assets |
{
  tag: (.tagName // ""),
  name: (.name // .tagName // ""),
  published_at: (.publishedAt // .createdAt),
  is_draft: (.isDraft // false),
  is_prerelease: (.isPrerelease // false),
  asset_count: ($assets | length),
  size: (reduce $assets[]? as $a (0; . + $a.size)),
  downloads: (reduce $assets[]? as $a (0; . + $a.downloads)),
  categories: (cat_summary($assets))
}
JQ
)

AGGREGATE_FILTER=$(cat <<'JQ'
def sum_values:
  reduce .[]? as $v (0; . + ($v // 0));

def merge_categories:
  reduce .[] as $rel ({};
    reduce (($rel.categories // {}) | to_entries[]) as $cat (. ;
      .[$cat.key] |= {
        assets: ((.assets // 0) + ($cat.value.assets // 0)),
        size: ((.size // 0) + ($cat.value.size // 0)),
        downloads: ((.downloads // 0) + ($cat.value.downloads // 0))
      }
    )
  )
  | to_entries
  | sort_by(.key)
  | from_entries;

. as $all |
($all | sort_by(.published_at // "") | reverse) as $sorted |
{
  repository: $repo,
  releases: $sorted,
  latest_tag: (
    $sorted
    | map(select(.published_at != null))
    | first?
    | if . == null then null else .tag end
  ),
  overall: {
    assets: ($sorted | map(.asset_count) | sum_values),
    size: ($sorted | map(.size) | sum_values),
    downloads: ($sorted | map(.downloads) | sum_values),
    categories: ($sorted | merge_categories)
  }
}
JQ
)

export GH_PAGER=cat

if [[ -z "$REPO" ]]; then
  if ! REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner'); then
    echo "Failed to determine current repository via gh." >&2
    exit 1
  fi
fi

if [[ -n "$TAG" ]]; then
  tags=("$TAG")
else
  if ! list_output=$(gh release list --limit "$LIMIT" --repo "$REPO"); then
    echo "Failed to list releases via gh." >&2
    exit 1
  fi
  tags=()
  while IFS=$'\t' read -r col1 col2 col3 col4; do
    tag_field="$col2"
    if [[ -n "$col4" ]]; then
      tag_field="$col3"
    fi
    [[ -n "$tag_field" ]] && tags+=("$tag_field")
  done <<< "$list_output"
fi

if [[ ${#tags[@]} -eq 0 ]]; then
  if [[ -n "$TAG" ]]; then
    printf 'No releases found for %s (tag %s).\n' "$REPO" "$TAG"
  else
    printf 'No releases found for %s.\n' "$REPO"
  fi
  exit 0
fi

tmpfile=$(mktemp)
cleanup() {
  rm -f "$tmpfile"
  rm -f "$tmpfile.err"
}
trap cleanup EXIT

for tag in "${tags[@]}"; do
  if ! release_json=$(gh release view "$tag" --repo "$REPO" --json tagName,name,publishedAt,createdAt,assets,isDraft,isPrerelease 2>"$tmpfile.err"); then
    cat "$tmpfile.err" >&2
    exit 1
  fi
  jq -c "$TRANSFORM_FILTER" <<< "$release_json" >> "$tmpfile"
  rm -f "$tmpfile.err"
 done

summary=$(jq -s --arg repo "$REPO" "$AGGREGATE_FILTER" "$tmpfile")

if [[ $JSON_OUTPUT -eq 1 ]]; then
  echo "$summary" | jq '.'
  exit 0
fi

release_count=$(echo "$summary" | jq '.releases | length')
if [[ $release_count -eq 0 ]]; then
  if [[ -n "$TAG" ]]; then
    printf 'No releases found for %s (tag %s).\n' "$REPO" "$TAG"
  else
    printf 'No releases found for %s.\n' "$REPO"
  fi
  exit 0
fi

latest_tag=$(echo "$summary" | jq -r '.latest_tag // empty')
overall_assets=$(echo "$summary" | jq -r '.overall.assets')
overall_size=$(echo "$summary" | jq -r '.overall.size')
overall_downloads=$(echo "$summary" | jq -r '.overall.downloads')

printf 'Repository: %s' "$REPO"
if [[ -n "$latest_tag" ]]; then
  printf ' | latest tag: %s' "$latest_tag"
fi
if [[ -z "$TAG" ]]; then
  printf ' | releases listed: %s' "$release_count"
else
  printf ' | releases listed: %s (filtered)' "$release_count"
fi
printf '\n'

printf 'Overall assets: %s | total size: %s | total downloads: %s\n' \
  "$overall_assets" "$(human_size "$overall_size")" "$overall_downloads"

overall_categories=$(echo "$summary" | jq -r '.overall.categories | to_entries | sort_by(.key) | .[]? | "\(.key)\t\(.value.size)\t\(.value.assets)"')
if [[ -n "$overall_categories" ]]; then
  printf 'Overall by category -> '
  first_cat=1
  while IFS=$'\t' read -r name size assets; do
    [[ -n "$name" ]] || continue
    if [[ $first_cat -eq 0 ]]; then
      printf ', '
    fi
    printf '%s: %s (%s assets)' "$name" "$(human_size "$size")" "$assets"
    first_cat=0
  done <<< "$overall_categories"
  printf '\n'
fi

echo "$summary" | jq -c '.releases[]' | while IFS= read -r release; do
  tag_name=$(echo "$release" | jq -r '.tag')
  published=$(echo "$release" | jq -r '.published_at // "unknown"')
  asset_count=$(echo "$release" | jq -r '.asset_count')
  size_bytes=$(echo "$release" | jq -r '.size')
  downloads=$(echo "$release" | jq -r '.downloads')
  is_draft=$(echo "$release" | jq -r '.is_draft')
  is_pre=$(echo "$release" | jq -r '.is_prerelease')

  flags=()
  [[ $is_draft == "true" ]] && flags+=("draft")
  [[ $is_pre == "true" ]] && flags+=("pre")

  flag_str=""
  if [[ ${#flags[@]} -gt 0 ]]; then
    flag_str=$(printf '%s, ' "${flags[@]}")
    flag_str=" (${flag_str%, })"
  fi

  printf '\n%s%s | published: %s\n' "$tag_name" "$flag_str" "$published"
  printf '  assets: %s | total size: %s | downloads: %s\n' \
    "$asset_count" "$(human_size "$size_bytes")" "$downloads"

  release_categories=$(echo "$release" | jq -r '.categories | to_entries | sort_by(.key) | .[]? | "\(.key)\t\(.value.size)\t\(.value.assets)\t\(.value.downloads)"')
  if [[ -n "$release_categories" ]]; then
    while IFS=$'\t' read -r name size assets downloads_cat; do
      [[ -n "$name" ]] || continue
      printf '    %-9s -> %s across %s assets (downloads: %s)\n' \
        "$name" "$(human_size "$size")" "$assets" "${downloads_cat:-0}"
    done <<< "$release_categories"
  fi

done
