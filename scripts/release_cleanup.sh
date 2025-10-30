#!/usr/bin/env bash
# Delete a GitHub release and its assets via gh with safety checks.

set -euo pipefail

TAG=""
REPO=""
FORCE=0
DRY_RUN=0
CLEANUP_TAG=0

usage() {
  cat <<'EOF'
Usage: release_cleanup.sh [options] --tag <tag>

Options:
  --tag <tag>        Release tag to delete (required)
  --repo <owner/repo>
                     Override repository (defaults to current gh repo)
  --force            Skip interactive confirmation
  --cleanup-tag      Remove the Git tag after deleting the release
  --dry-run          Show what would be deleted without performing it
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
    --force)
      FORCE=1
      shift
      ;;
    --cleanup-tag)
      CLEANUP_TAG=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

if [[ -z "$TAG" ]]; then
  echo "Error: --tag is required." >&2
  usage >&2
  exit 1
fi

ensure_command gh
ensure_command jq
export GH_PAGER=cat

if [[ -z "$REPO" ]]; then
  if ! REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner'); then
    echo "Failed to determine current repository via gh." >&2
    exit 1
  fi
fi

if ! release_json=$(gh release view "$TAG" --repo "$REPO" --json tagName,name,publishedAt,assets,isDraft,isPrerelease); then
  echo "Release '$TAG' not found in $REPO." >&2
  exit 1
fi

asset_count=$(jq -r '[.assets[]?] | length' <<< "$release_json")
total_size=$(jq -r '[.assets[]?.size] | add // 0' <<< "$release_json")
total_downloads=$(jq -r '[.assets[]?.downloadCount] | add // 0' <<< "$release_json")
release_name=$(jq -r '.name // .tagName // "(untitled)"' <<< "$release_json")
published_at=$(jq -r '.publishedAt // "unknown"' <<< "$release_json")

printf 'About to delete release %s (%s) from %s\n' "$TAG" "$release_name" "$REPO"
printf '  published at: %s\n' "$published_at"
printf '  assets: %s | total size: %s | downloads recorded: %s\n' \
  "$asset_count" "$(human_size "$total_size")" "$total_downloads"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run enabled; release not deleted."
  exit 0
fi

if [[ $FORCE -ne 1 ]]; then
  read -rp "Type 'delete' to confirm: " answer
  if [[ "$answer" != "delete" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

cmd=(gh release delete "$TAG" --repo "$REPO" -y)
if [[ $CLEANUP_TAG -eq 1 ]]; then
  cmd+=(--cleanup-tag)
fi

if "${cmd[@]}"; then
  echo "Release '$TAG' deleted successfully."
  if [[ $CLEANUP_TAG -eq 1 ]]; then
    echo "Associated Git tag removed."
  fi
else
  status=$?
  echo "Failed to delete release '$TAG'." >&2
  exit "$status"
fi
