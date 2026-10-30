#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for scripts/image-pins.sh and scripts/docker-prune.sh, run
# against a stubbed `docker` (no daemon needed).
#
# What it proves:
#   - moving tags are refused, so .env can only ever hold a pinned ref
#   - promote pins the pulled image's digest, keeps unrelated .env lines
#   - rollback re-pins the previous known-good release in .env -- the value a
#     later `docker compose pull` resolves -- instead of retagging :release
#     locally, and forgets the bad release so it is never rolled back *to*
#   - seed pins what each container runs now, by digest, without overwriting
#   - prune keeps the pinned image + IMAGE_KEEP_GOOD known-good per service,
#     removes older ones of managed repos only, and removes nothing at all
#     while any service is unpinned

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$ROOT/scripts/image-pins.sh"
PRUNE="$ROOT/scripts/docker-prune.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin" FIX="$TMP/fix"
mkdir -p "$BIN" "$FIX"/{containers,digests,ids,images,images-fail}
export IMAGE_PINS_ENV_FILE="$TMP/.env" IMAGE_PINS_STATE_DIR="$TMP/state" FIX PINS_LOCK_TRIES=2
export PATH="$BIN:$PATH"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }
key() { printf '%s' "$1" | tr '/:@' '___'; }
dg() { printf 'sha256:%064d' "$1"; }  # deterministic fake digest

cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
# Minimal docker stand-in driven by files under $FIX. Logs every call.
k() { printf '%s' "$1" | tr '/:@' '___'; }
echo "$*" >>"$FIX/calls.log"
[ -e "$FIX/slow" ] && sleep 2
last="${*: -1}"
case "$1 ${2:-}" in
  "inspect --format") cat "$FIX/containers/$(k "$last")" 2>/dev/null || exit 1 ;;
  "image inspect")
    case "$4" in
      *RepoDigests*) cat "$FIX/digests/$(k "$last")" 2>/dev/null || exit 1 ;;
      *.Id*) cat "$FIX/ids/$(k "$last")" 2>/dev/null || exit 1 ;;
    esac ;;
  "images --no-trunc")
    [ -e "$FIX/images-fail/$(k "$last")" ] && { echo "docker stub: cannot list $last" >&2; exit 1; }
    cat "$FIX/images/$(k "$last")" 2>/dev/null || true ;;
  "image rm")
    grep -qxF -- "$last" "$FIX/inuse" 2>/dev/null && exit 1
    echo "$last" >>"$FIX/rm.log" ;;
  "image prune") ;;
  *) echo "docker stub: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BIN/docker"

env_value() { sed -n "s/^$1=//p" "$IMAGE_PINS_ENV_FILE"; }
history_of() { cat "$IMAGE_PINS_STATE_DIR/$1.history" 2>/dev/null || true; }
expect_refused() { if "$PINS" "$@" 2>/dev/null; then fail "accepted: $*"; fi; }

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333
REPO=ghcr.io/zenvoraai/dayandyou
# What `docker image inspect` reports after the deploy pulled each tag.
for n in 1 2 3; do
  sha="$(printf "%040d" 0 | tr 0 "$n")"
  echo "$REPO@$(dg "$n")" >"$FIX/digests/$(key "$REPO:$sha")"
done

# --- refusing moving tags ----------------------------------------------------
printf 'GHCR_OWNER=zenvoraai\n' >"$IMAGE_PINS_ENV_FILE"
for bad in latest release staging abc123 "$SHA1 x" "$SHA1@sha256:short" "release@sha256:$(printf '%064d' 1)x"; do
  expect_refused promote dayandyou-prod "$bad"
done
expect_refused promote nginx nginx:1.27-alpine
expect_refused promote nginx "nginx:1.27-alpine@$(dg 9)
X=1"
expect_refused promote no-such-service "$SHA1"
[ "$(cat "$IMAGE_PINS_ENV_FILE")" = "GHCR_OWNER=zenvoraai" ] || fail "a refused promote changed .env:\n$(cat "$IMAGE_PINS_ENV_FILE")"

# --- promote pins the digest ---------------------------------------------------
"$PINS" promote dayandyou-prod "$SHA1" >/dev/null
[ "$(env_value DAYANDYOU_PROD_TAG)" = "$SHA1@$(dg 1)" ] || fail "promote did not pin the digest: $(env_value DAYANDYOU_PROD_TAG)"
[ "$(env_value GHCR_OWNER)" = zenvoraai ] || fail "promote dropped an unrelated .env line"
"$PINS" promote dayandyou-prod "$SHA2" >/dev/null
"$PINS" promote dayandyou-prod "$SHA2" >/dev/null   # re-run of the same deploy
[ "$(history_of DAYANDYOU_PROD_TAG)" = "$SHA1@$(dg 1)
$SHA2@$(dg 2)" ] || fail "unexpected history:\n$(history_of DAYANDYOU_PROD_TAG)"
[ "$(grep -c '^DAYANDYOU_PROD_TAG=' "$IMAGE_PINS_ENV_FILE")" = 1 ] || fail ".env has duplicate DAYANDYOU_PROD_TAG lines"
[ "$("$PINS" get dayandyou-prod)" = "$SHA2@$(dg 2)" ] || fail "get does not return the pinned value"

# --- rollback must name the release it is rolling back from ------------------
# Run after a deploy that failed before promote, a bare rollback would step
# back from the still-good pin and drop it from history.
before="$(cat "$IMAGE_PINS_ENV_FILE")"
expect_refused rollback dayandyou-prod
expect_refused rollback dayandyou-prod "$SHA1"
[ "$(cat "$IMAGE_PINS_ENV_FILE")" = "$before" ] || fail "a refused rollback changed .env"
[ "$(history_of DAYANDYOU_PROD_TAG | wc -l | tr -d ' ')" = 2 ] || fail "a refused rollback changed the history"

# --- rollback re-pins, not retags ---------------------------------------------
: >"$FIX/calls.log"
"$PINS" rollback dayandyou-prod "$SHA2" >/dev/null
[ "$(env_value DAYANDYOU_PROD_TAG)" = "$SHA1@$(dg 1)" ] || fail "rollback did not re-pin the previous release: $(env_value DAYANDYOU_PROD_TAG)"
[ "$(history_of DAYANDYOU_PROD_TAG)" = "$SHA1@$(dg 1)" ] || fail "rollback kept the bad release as known-good"
grep -q '^tag ' "$FIX/calls.log" && fail "rollback retagged an image"
. "$ROOT/scripts/lib/image-pins-lib.sh"
resolved="$(pins_full_ref DAYANDYOU_PROD_TAG "$(env_value DAYANDYOU_PROD_TAG)")"
[ "$resolved" = "$REPO:$SHA1@$(dg 1)" ] || fail "compose would resolve $resolved, not the rolled-back digest"
before="$(cat "$IMAGE_PINS_ENV_FILE")"
expect_refused rollback dayandyou-prod "$SHA1@$(dg 1)"
[ "$(cat "$IMAGE_PINS_ENV_FILE")" = "$before" ] || fail "a refused rollback changed .env"
[ "$(env_value DAYANDYOU_STAGING_TAG)" = "" ] || fail "prod promote/rollback touched staging"

# --- .env keeps its mode; `export VAR=` lines are understood ---------------------
chmod 640 "$IMAGE_PINS_ENV_FILE"
"$PINS" promote dayandyou-prod "$SHA2" >/dev/null
mode="$(stat -c %a "$IMAGE_PINS_ENV_FILE" 2>/dev/null || stat -f %Lp "$IMAGE_PINS_ENV_FILE")"
[ "$mode" = 640 ] || fail "promote changed .env's mode to $mode (compose run as another user could no longer read it)"
"$PINS" rollback dayandyou-prod "$SHA2" >/dev/null
echo "export FAMILY_API_TAG=$SHA3@$(dg 3)" >>"$IMAGE_PINS_ENV_FILE"
[ "$("$PINS" get api)" = "$SHA3@$(dg 3)" ] || fail "get ignores an 'export VAR=' line, which compose reads"
echo "$REPO@$(dg 3)" >"$FIX/digests/$(key "ghcr.io/zenvoraai/family-media-api:$SHA2")"
"$PINS" promote api "$SHA2" >/dev/null 2>&1
[ "$(grep -c 'FAMILY_API_TAG=' "$IMAGE_PINS_ENV_FILE")" = 1 ] || fail "promote left a second FAMILY_API_TAG line:\n$(cat "$IMAGE_PINS_ENV_FILE")"
sed -i.bak '/FAMILY_API_TAG=/d' "$IMAGE_PINS_ENV_FILE"; rm -f "$IMAGE_PINS_ENV_FILE.bak" "$IMAGE_PINS_STATE_DIR/FAMILY_API_TAG.history"

# --- a value whose digest cannot be resolved is pinned, but not silently ---------
"$PINS" promote memorial-api "$SHA3" >/dev/null 2>"$TMP/nodigest.err" || fail "promote of a bare SHA failed"
grep -q "no local digest" "$TMP/nodigest.err" || fail "promote stored a bare SHA without warning"
sed -i.bak '/MEMORIAL_API_TAG=/d' "$IMAGE_PINS_ENV_FILE"; rm -f "$IMAGE_PINS_ENV_FILE.bak" "$IMAGE_PINS_STATE_DIR/MEMORIAL_API_TAG.history"

# --- seed pins what runs now --------------------------------------------------
seed_container() {  # name config-image image-id repo-digest-lines
  echo "$2|$3" >"$FIX/containers/$1"
  printf '%s\n' "$4" >"$FIX/digests/$(key "$3")"
}
seed_container homelab-nginx nginx:1.27-alpine sha256:img-nginx "nginx@$(dg 20)"
seed_container homelab-docker-api-filter nginx:1.27-alpine sha256:img-nginx "nginx@$(dg 20)"
seed_container homelab-docker-socket-proxy tecnativa/docker-socket-proxy:0.3 sha256:img-dsp "tecnativa/docker-socket-proxy@$(dg 21)"
seed_container homelab-family-api "ghcr.io/zenvoraai/family-media-api:$SHA3" sha256:img-fam "ghcr.io/zenvoraai/family-media-api@$(dg 22)"
seed_container homelab-securevault-api ghcr.io/zenvoraai/securevault-api:latest sha256:img-sv "ghcr.io/zenvoraai/securevault-api@$(dg 23)"
# Already pinned by promote above; seed must not replace it with :release.
seed_container homelab-dayandyou-prod "$REPO:release" sha256:img-dyp "$REPO@$(dg 30)"
seed_container homelab-dayandyou-staging "$REPO:staging" sha256:img-dys "$REPO@$(dg 24)"
seed_container homelab-memorial-api ghcr.io/zenvoraai/aiqiuqi-memorial-api:latest sha256:img-ma "ghcr.io/zenvoraai/aiqiuqi-memorial-api@$(dg 25)"
seed_container homelab-memorial-worker ghcr.io/zenvoraai/aiqiuqi-memorial-worker:latest sha256:img-mw "ghcr.io/zenvoraai/aiqiuqi-memorial-worker@$(dg 26)"
# Running from the pre-transfer namespace: must not be pinned against zenvoraai.
seed_container homelab-zenvora-admin ghcr.io/qclawchang/zenvora-admin:latest sha256:img-za "ghcr.io/qclawchang/zenvora-admin@$(dg 27)"

if "$PINS" seed >/dev/null 2>"$TMP/seed.err"; then fail "seed succeeded although zenvora-admin runs a foreign repo"; fi
grep -q 'homelab-zenvora-admin runs ghcr.io/qclawchang' "$TMP/seed.err" || fail "seed did not explain the foreign repo:\n$(cat "$TMP/seed.err")"
[ "$(env_value DAYANDYOU_PROD_TAG)" = "$SHA1@$(dg 1)" ] || fail "seed overwrote an existing pin"
[ "$(env_value DAYANDYOU_STAGING_TAG)" = "staging@$(dg 24)" ] || fail "staging seeded as $(env_value DAYANDYOU_STAGING_TAG)"
[ "$(env_value SECUREVAULT_API_TAG)" = "latest@$(dg 23)" ] || fail ":latest must be seeded with its digest"
[ "$(env_value NGINX_IMAGE)" = "nginx:1.27-alpine@$(dg 20)" ] || fail "nginx seeded as $(env_value NGINX_IMAGE)"
[ "$(env_value DOCKER_SOCKET_PROXY_IMAGE)" = "tecnativa/docker-socket-proxy:0.3@$(dg 21)" ] || fail "proxy seeded as $(env_value DOCKER_SOCKET_PROXY_IMAGE)"
[ -z "$(env_value ZENVORA_ADMIN_TAG)" ] || fail "foreign-repo zenvora-admin was pinned"
if "$PINS" check >/dev/null 2>&1; then fail "check passed with ZENVORA_ADMIN_TAG unset"; fi

# --- prune refuses while anything is unpinned ----------------------------------
echo "aaaa $REPO $SHA2 $(dg 2)" >"$FIX/images/$(key "$REPO")"
: >"$FIX/calls.log"
if "$PRUNE" >/dev/null 2>&1; then fail "prune ran with an unpinned service"; fi
[ ! -s "$FIX/rm.log" ] || fail "prune removed images with an unpinned service"
grep -q 'image prune' "$FIX/calls.log" && fail "prune touched dangling images with an unpinned service"

# --- prune keeps the window ---------------------------------------------------
"$PINS" promote zenvora-admin "$SHA1" >/dev/null
"$PINS" check >/dev/null || fail "check failed with every variable pinned"
# dayandyou-prod history: 5 releases; the newest 3 + the pinned one are kept.
for n in 4 5 6 7; do
  sha="$(printf "%040d" 0 | tr 0 "$n")"
  echo "$REPO@$(dg "$n")" >"$FIX/digests/$(key "$REPO:$sha")"
  "$PINS" promote dayandyou-prod "$sha" >/dev/null
done
for n in 1 4 5 6 7 24; do echo "id-$n" >"$FIX/ids/$(key "$REPO@$(dg "$n")")"; done
{
  for n in 1 4 5 6 7; do sha="$(printf "%040d" 0 | tr 0 "$n")"; echo "id-$n $REPO $sha $(dg "$n")"; done
  echo "id-24 $REPO <none> $(dg 24)"           # staging, pulled by digest
  echo "id-old $REPO release $(dg 99)"         # the old moving tag
  echo "id-busy $REPO staging $(dg 98)"        # used by a stopped container
} >"$FIX/images/$(key "$REPO")"
echo "$REPO:staging" >"$FIX/inuse"
# Every other variable's current pin is a local image.
for var in $(pins_vars); do
  f="$FIX/ids/$(key "$(pins_lookup_ref "$(pins_full_ref "$var" "$(env_value "$var")")")")"
  [ -e "$f" ] || echo "id-$var" >"$f"
done

# --- prune refuses when a pinned image does not resolve locally ------------------
# (inspect format change, containerd store, image removed by hand): an empty
# keep set for that repo would remove its rollback images.
mv "$FIX/ids/$(key "$REPO@$(dg 7)")" "$TMP/id7"
: >"$FIX/rm.log"
if "$PRUNE" >"$TMP/unresolved.out" 2>&1; then fail "prune ran although the pinned dayandyou-prod image does not resolve"; fi
[ ! -s "$FIX/rm.log" ] || fail "prune removed images although a pin does not resolve:\n$(cat "$FIX/rm.log")"
grep -q 'DAYANDYOU_PROD_TAG.*does not resolve' "$TMP/unresolved.out" || fail "prune did not say which pin failed:\n$(cat "$TMP/unresolved.out")"
mv "$TMP/id7" "$FIX/ids/$(key "$REPO@$(dg 7)")"

# --- prune waits for the pins lock ----------------------------------------------
mkdir "$IMAGE_PINS_STATE_DIR/.lock"; echo "$$" >"$IMAGE_PINS_STATE_DIR/.lock/pid"   # held by this live shell
if "$PRUNE" >/dev/null 2>&1; then fail "prune ran while a live process held the pins lock"; fi
[ ! -s "$FIX/rm.log" ] || fail "prune removed images without the pins lock"
rm -rf "$IMAGE_PINS_STATE_DIR/.lock"
echo "id-other ghcr.io/qclawchang/zenvora-admin latest <none>" >"$FIX/images/$(key ghcr.io/qclawchang/zenvora-admin)"
: >"$FIX/rm.log"
"$PRUNE" >"$TMP/prune.out" 2>&1 || fail "prune failed:\n$(cat "$TMP/prune.out")"
sha1="$(printf "%040d" 0 | tr 0 1)" sha4="$(printf "%040d" 0 | tr 0 4)"
[ "$(sort "$FIX/rm.log")" = "$(printf '%s\n' "$REPO:$sha1" "$REPO:$sha4" "$REPO:release" | sort)" ] \
  || fail "prune removed the wrong set (expected the 2 oldest releases + :release):\n$(cat "$FIX/rm.log")"
grep -q "kept $REPO:staging" "$TMP/prune.out" || fail "an in-use image was not reported as kept"
grep -q qclawchang "$FIX/calls.log" && fail "prune looked at a repository it does not manage"
[ ! -d "$IMAGE_PINS_STATE_DIR/.lock" ] || fail "prune left the pins lock behind"

# --- a repo that cannot be listed is reported, not read as empty ------------------
touch "$FIX/images-fail/$(key "$REPO")"
if "$PRUNE" >"$TMP/listfail.out" 2>&1; then fail "prune exited 0 although it could not list $REPO"; fi
grep -q "could not list images of $REPO" "$TMP/listfail.out" || fail "listing failure not reported:\n$(cat "$TMP/listfail.out")"
rm "$FIX/images-fail/$(key "$REPO")"

# --- a lock left by a killed process is cleared; a live holder is waited on -----
sh -c 'exit 0' & dead=$!; wait "$dead"
mkdir "$IMAGE_PINS_STATE_DIR/.lock"; echo "$dead" >"$IMAGE_PINS_STATE_DIR/.lock/pid"
"$PINS" promote dayandyou-prod "$(printf "%040d" 0 | tr 0 7)" >/dev/null 2>"$TMP/stale.err" || fail "promote failed on a stale lock:\n$(cat "$TMP/stale.err")"
grep -q "stale lock" "$TMP/stale.err" || fail "stale lock cleared silently"
mkdir "$IMAGE_PINS_STATE_DIR/.lock"; echo "$$" >"$IMAGE_PINS_STATE_DIR/.lock/pid"
if "$PINS" promote dayandyou-prod "$(printf "%040d" 0 | tr 0 7)" >/dev/null 2>&1; then fail "promote took a lock held by a live process"; fi
rm -rf "$IMAGE_PINS_STATE_DIR/.lock"

: >"$FIX/rm.log"
IMAGE_KEEP_GOOD=1 DRY_RUN=1 "$PRUNE" >"$TMP/dry.out"
[ ! -s "$FIX/rm.log" ] || fail "DRY_RUN removed images"
grep -q "would remove $REPO:$(printf "%040d" 0 | tr 0 6)" "$TMP/dry.out" || fail "IMAGE_KEEP_GOOD=1 should drop the second-newest release:\n$(cat "$TMP/dry.out")"
if IMAGE_KEEP_GOOD=0 "$PRUNE" >/dev/null 2>&1; then fail "IMAGE_KEEP_GOOD=0 accepted"; fi

# --- a killed run leaves a lock that names it; a TERM stops the run ------------
# seed takes the lock, then calls docker (slowed here) for every unset variable.
lockrun() {  # runs seed in the background against a fresh, empty .env
  IMAGE_PINS_ENV_FILE="$TMP/sig.env" IMAGE_PINS_STATE_DIR="$TMP/sig" "$PINS" seed >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 50); do [ -s "$TMP/sig/.lock/pid" ] && break; sleep 0.1; done
}
rm -rf "$TMP/sig"; : >"$TMP/sig.env"; touch "$FIX/slow"
lockrun
[ "$(cat "$TMP/sig/.lock/pid" 2>/dev/null)" = "$pid" ] || fail "the lock does not record its holder's PID ($pid)"
kill -KILL "$pid"; wait "$pid" 2>/dev/null || true
[ -d "$TMP/sig/.lock" ] || fail "test setup: SIGKILL should leave the lock behind"
rm -f "$FIX/slow"
IMAGE_PINS_ENV_FILE="$TMP/sig.env" IMAGE_PINS_STATE_DIR="$TMP/sig" "$PINS" promote dayandyou-prod "$SHA1" >/dev/null 2>&1 \
  || fail "the lock of a SIGKILLed run blocked the next promote"
: >"$TMP/sig.env"; touch "$FIX/slow"
lockrun
kill -TERM "$pid"; status=0; wait "$pid" || status=$?
rm -f "$FIX/slow"
[ "$status" = 143 ] || fail "a TERMed run exited $status, not 143 (it kept going after releasing the lock)"
[ ! -s "$TMP/sig.env" ] || fail "a TERMed run went on to write .env unlocked:\n$(cat "$TMP/sig.env")"
[ ! -d "$TMP/sig/.lock" ] || fail "a TERMed run left its lock"

echo "PASS: image pins refuse moving tags, roll back by re-pinning, and prune keeps the known-good window"
