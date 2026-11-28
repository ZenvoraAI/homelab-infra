# shellcheck shell=bash
# Shared by the three memorial refresh tests: since /env/aiqiuqi-memorial/api
# became the source of api.env (README "Env files from SSM"), each refresh
# script must refuse that file before fetching anything (secretlib_refuse_canonical),
# by its usual path under any root, and by another name for it (a symlink);
# a file that is not the canonical one still gets past the guard.
#
#   refresh_guard_test <script> <label>

refresh_guard_test() {
  local script=$1 label=$2 tmp bin out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: tmp is local
  trap "rm -rf '$tmp'" EXIT
  bin="$tmp/bin"; mkdir -p "$bin" "$tmp/opt/secrets/aiqiuqi-memorial" "$tmp/root/aiqiuqi-memorial" "$tmp/elsewhere"
  printf '#!/usr/bin/env bash\necho "aws $*" >>"%s/aws.log"\nexit 1\n' "$tmp" >"$bin/aws"
  printf '#!/usr/bin/env bash\necho 1000:1000\n' >"$bin/stat"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/chown"
  chmod +x "$bin"/*
  for d in "$tmp/opt/secrets/aiqiuqi-memorial" "$tmp/root/aiqiuqi-memorial" "$tmp/elsewhere"; do
    printf 'APP_KEY=base64:old\nAWS_ACCESS_KEY_ID=old\n' >"$d/api.env"; chmod 600 "$d/api.env"
  done
  ln -s "$tmp/root/aiqiuqi-memorial" "$tmp/link"
  cp "$tmp/root/aiqiuqi-memorial/api.env" "$tmp/orig"

  run_it() { # secrets dir
    env PATH="$bin:$PATH" SECRETS_DIR="$1" ENVSSM_SECRETS_ROOT="$tmp/root" sh "$script" 2>&1
  }
  # The usual layout under another root, and a symlinked directory.
  for dir in "$tmp/opt/secrets/aiqiuqi-memorial" "$tmp/link"; do
    rm -f "$tmp/aws.log"
    if out="$(run_it "$dir")"; then fail "$label: $dir/api.env must be refused:\n$out"; fi
    grep -q 'comes from SSM /env' <<<"$out" || fail "$label: expected the canonical refusal for $dir/api.env, got:\n$out"
    [ ! -e "$tmp/aws.log" ] || fail "$label: SSM was read before the refusal ($dir)"
    cmp -s "$dir/api.env" "$tmp/orig" || fail "$label: $dir/api.env was changed"
    compgen -G "$dir/api.env.bak-*" >/dev/null && fail "$label: a .bak was made ($dir)"
  done
  # Not the canonical file: past the guard (it reaches SSM, which fails here).
  rm -f "$tmp/aws.log"
  out="$(run_it "$tmp/elsewhere")" || true
  grep -q 'comes from SSM /env' <<<"$out" && fail "$label: a non-canonical file was refused:\n$out"
  [ -e "$tmp/aws.log" ] || fail "$label: a non-canonical target did not get past the guard:\n$out"
  return 0
}
