# Shared helpers for the refresh-*-secrets.sh scripts. Not standalone --
# sourced with `. "$(dirname "$0")/lib/secret-file-lib.sh"`.
#
# Covers the two steps that are identical across every refresh script:
# rotating to exactly one backup before a rewrite (an exposed secret must
# stop existing on disk once rotated, not accumulate in backups next to the
# file that replaced it), and installing the new file at 0600 owned by
# whoever owned the original (these scripts run under sudo; docker compose,
# which reads the file, does not -- a root-owned rewrite would lock compose
# out of a file it could read a moment ago). Each script still assembles its
# own replacement content -- that part is genuinely different per script and
# isn't touched here.

# Prints "$ENV_FILE.new"'s destined owner, in `chown`'s uid:gid form.
secretlib_orig_owner() {
  stat -c '%u:%g' "$1"
}

# Keeps only the most recent backup, creates today's at 0600 directly (no
# window where a plain `cp` would leave it at the umask's default mode), and
# prints its path.
secretlib_rotate_backup() {
  env_file="$1"
  orig_owner="$2"
  for old in $(ls -t "$env_file".bak-* 2>/dev/null | tail -n +2); do
    rm -f "$old"
  done
  backup="$env_file.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 600 "$env_file" "$backup"
  chown "$orig_owner" "$backup"
  printf '%s\n' "$backup"
}

# Installs the already-assembled "$env_file.new" over "$env_file", at 0600
# owned by orig_owner. Caller is responsible for writing "$env_file.new"
# under `umask 077` first.
secretlib_finalize() {
  env_file="$1"
  orig_owner="$2"
  mv "$env_file.new" "$env_file"
  chown "$orig_owner" "$env_file"
  chmod 600 "$env_file"
}
