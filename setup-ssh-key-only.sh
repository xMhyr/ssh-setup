#!/usr/bin/env bash
# Configure standard Linux OpenSSH for root key-only login on TCP port 22.
# Usage: sudo bash setup-ssh-key-only.sh [path/to/public-key.pub]
# If no path is supplied, paste your public key into EMBEDDED_PUBLIC_KEY below.
set -Eeuo pipefail
umask 077

EMBEDDED_PUBLIC_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCb2rL/NYEHvi9JmRdu1mW4n0cpzPV6ClebfV52b1ehI8LCqkEJIcSPC8/GJRFzLhMHGXb5dsNpneK3MslMlzSEQnl/zR6Gug4VdWa1zKqdFnx8YpbOPPfHQflS5vsOj+lp7qvnHUXpyGXtUdXSj8avSdB1lSFr32p5tMZFAFAygUjfVmGTnWGetQVwMtLJMkwG+OO1cynZYrKFV0ZXJTFQcc86U4YrQSMHEb+I4ncQ9qstswQ3c/PS1OR125cIxsiDnjZF9PJH8cOND1bug2dpmp83ZfOohQ3iSvUIxhH5wAHQKrOThYA1HVc/ovJRP0KjqAl1ScmpoCqO84jrawNl mhyr'
MAIN='/etc/ssh/sshd_config'
MARK_BEGIN='# BEGIN managed-ssh-key-only'
MARK_END='# END managed-ssh-key-only'
SOCKET_FILE_NAME='zzzz-managed-ssh-port22.conf'

say() { printf '%s\n' "[ssh-setup] $*"; }
fail() { printf '%s\n' "[ssh-setup] ERROR: $*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail 'Run as root (sudo bash ...).'
[[ -f "$MAIN" ]] || fail "Missing $MAIN; this script is for standard OpenSSH installations."
[[ ! -L "$MAIN" ]] || fail "Refusing to modify symlink: $MAIN"
SSHD=$(command -v sshd 2>/dev/null || true)
if [[ -z "$SSHD" ]]; then
  for candidate in /usr/sbin/sshd /sbin/sshd; do
    if [[ -x "$candidate" ]]; then SSHD="$candidate"; break; fi
  done
fi
[[ -n "$SSHD" ]] || fail 'OpenSSH server (sshd) is not installed.'
command -v ssh-keygen >/dev/null || fail 'ssh-keygen was not found.'

if [[ $# -gt 1 ]]; then fail 'Usage: bash setup-ssh-key-only.sh [your_key.pub]'; fi
if [[ $# -eq 1 ]]; then
  [[ -r "$1" ]] || fail "Cannot read public key file: $1"
  PUBLIC_KEY=$(grep -vE '^[[:space:]]*(#|$)' "$1" || true)
else
  PUBLIC_KEY=$EMBEDDED_PUBLIC_KEY
fi
[[ -n "$PUBLIC_KEY" && "$PUBLIC_KEY" != *$'\n'* ]] || fail 'Provide exactly one public key.'
case "$PUBLIC_KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*\ *) ;;
  *) fail 'Expected an SSH PUBLIC key (e.g. ssh-ed25519 AAAA...), not a private key.' ;;
esac
[[ "$PUBLIC_KEY" != PASTE_YOUR_FULL_SSH_PUBLIC_KEY_HERE ]] || fail 'Replace EMBEDDED_PUBLIC_KEY or pass a .pub file.'
KEY_TMP=$(mktemp)
trap 'rm -f "$KEY_TMP"' EXIT
printf '%s\n' "$PUBLIC_KEY" > "$KEY_TMP"
ssh-keygen -l -f "$KEY_TMP" >/dev/null 2>&1 || fail 'Invalid SSH public key. Never paste a private key here.'

# Refuse nonstandard symlinked files to ensure backups really cover changes.
shopt -s nullglob
CONFIG_FILES=( "$MAIN" /etc/ssh/sshd_config.d/*.conf )
for f in "${CONFIG_FILES[@]}"; do
  [[ ! -L "$f" ]] || fail "Refusing to modify symlink: $f"
done
[[ ! -L /root/.ssh && ! -L /root/.ssh/authorized_keys ]] || fail 'Refusing symlinked root SSH paths.'

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP=$(mktemp -d "/root/ssh-setup-backup-${STAMP}-XXXXXX")
ARCHIVE="$BACKUP/original-files.tar"
BACKUP_PATHS=( etc/ssh/sshd_config )
[[ -d /etc/ssh/sshd_config.d ]] && BACKUP_PATHS+=( etc/ssh/sshd_config.d )
[[ -f /root/.ssh/authorized_keys ]] && BACKUP_PATHS+=( root/.ssh/authorized_keys )
SOCKET_UNITS=()
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
  for unit in ssh.socket sshd.socket; do
    if systemctl is-active --quiet "$unit"; then
      SOCKET_UNITS+=( "$unit" )
      [[ -d "/etc/systemd/system/$unit.d" ]] && BACKUP_PATHS+=( "etc/systemd/system/$unit.d" )
    fi
  done
fi
tar -C / -cpf "$ARCHIVE" "${BACKUP_PATHS[@]}"
printf '%s\n' "${SOCKET_UNITS[@]}" > "$BACKUP/active-sockets.txt"

# This rollback script can be run from the existing session/console.
cat > "$BACKUP/rollback.sh" <<ROLLBACK
#!/usr/bin/env bash
set -e
for unit in ${SOCKET_UNITS[*]:-}; do
  rm -f "/etc/systemd/system/\$unit.d/$SOCKET_FILE_NAME"
done
tar -C / -xpf '$ARCHIVE'
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  for unit in ${SOCKET_UNITS[*]:-}; do systemctl restart "\$unit"; done
  for unit in ssh.service sshd.service; do
    if systemctl is-active --quiet "\$unit"; then
      systemctl reload "\$unit" || systemctl restart "\$unit"
    fi
  done
fi
printf 'Restored backed-up SSH configuration. Verify connectivity.\\n'
ROLLBACK
chmod 700 "$BACKUP/rollback.sh"
say "Backup: $BACKUP"

restore_before_activation() {
  trap - ERR
  say 'Configuration check failed; restoring original SSH files.'
  # Do not restart the service: no new config has been activated yet.
  for unit in "${SOCKET_UNITS[@]}"; do
    rm -f "/etc/systemd/system/$unit.d/$SOCKET_FILE_NAME"
  done
  tar -C / -xpf "$ARCHIVE"
  exit 1
}

# If any pre-activation command fails, restore configuration rather than leave it half-edited.
trap 'restore_before_activation' ERR

# Add the key before touching password authentication.
install -d -m 700 -o root -g root /root/.ssh
touch /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
grep -Fqx -- "$PUBLIC_KEY" /root/.ssh/authorized_keys || printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys

# Port can occur multiple times. Disable old Port directives in the
# normal config files. Preserve restricted ListenAddress bindings, changing
# only an explicitly configured port on those addresses to 22.
# Move our global settings to the *top*, before any Include statement.
for file in "${CONFIG_FILES[@]}"; do
  TMP=$(mktemp)
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    $0 == begin { managed = 1; next }
    $0 == end { managed = 0; next }
    managed { next }
    /^[[:space:]]*#/ { print; next }
    tolower($1) == "port" {
      print "# disabled by ssh-setup: " $0; next
    }
    tolower($1) == "listenaddress" {
      # IPv4/hostname:port or [IPv6]:port. Bare IPv6 addresses stay unchanged.
      if ($2 ~ /^\[[^]]+\]:[[:digit:]]+$/ || $2 ~ /^[^:]+:[[:digit:]]+$/) {
        sub(/:[[:digit:]]+$/, ":22", $2)
        print; next
      }
    }
    { print }
  ' "$file" > "$TMP"
  if [[ "$file" == "$MAIN" ]]; then
    {
      printf '%s\n' "$MARK_BEGIN"
      cat <<'SETTINGS'
Port 22
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
AuthorizedKeysFile .ssh/authorized_keys
SETTINGS
      printf '%s\n' "$MARK_END"
      cat "$TMP"
    } > "$file"
  else
    cat "$TMP" > "$file"
  fi
  rm -f "$TMP"
  command -v restorecon >/dev/null 2>&1 && restorecon "$file" >/dev/null 2>&1 || true
done

# On Ubuntu and some other systemd systems, the ssh.socket unit controls the
# TCP listening port independently of an already running sshd process.
for unit in "${SOCKET_UNITS[@]}"; do
  install -d -m 755 "/etc/systemd/system/$unit.d"
  printf '[Socket]\nListenStream=\nListenStream=22\n' > "/etc/systemd/system/$unit.d/$SOCKET_FILE_NAME"
done

# Check syntax and *effective* values (including Include files and Match rules).
[[ -d /run/sshd ]] || install -d -m 755 /run/sshd
"$SSHD" -t || restore_before_activation
read -r CLIENT_IP _ SERVER_IP _ <<< "${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}"
CLIENT_IP=${CLIENT_IP:-127.0.0.1}
SERVER_IP=${SERVER_IP:-127.0.0.1}
EFFECTIVE=$("$SSHD" -T -C "user=root,host=localhost,addr=$CLIENT_IP,laddr=$SERVER_IP,lport=22") || restore_before_activation
required=(
  'permitrootlogin yes'
  'pubkeyauthentication yes'
  'passwordauthentication no'
  'kbdinteractiveauthentication no'
  'authenticationmethods publickey'
  'authorizedkeysfile .ssh/authorized_keys'
)
for setting in "${required[@]}"; do
  printf '%s\n' "$EFFECTIVE" | grep -Fqx "$setting" || {
    say "Effective configuration does not match: $setting"
    restore_before_activation
  }
done
PORTS=$(printf '%s\n' "$EFFECTIVE" | awk '$1 == "port" { print $2 }' | sort -u)
[[ "$PORTS" == '22' ]] || { say "Unexpected effective SSH ports: $PORTS"; restore_before_activation; }
if ! printf '%s\n' "$EFFECTIVE" | awk '
  $1 == "listenaddress" && $2 ~ /:[[:digit:]]+$/ && $2 !~ /:22$/ { bad=1 }
  END { exit bad }
'; then
  say 'A custom Include or Match keeps a ListenAddress with another port.'
  restore_before_activation
fi
say 'Configuration validation passed.'
trap - ERR

# Permit TCP/22 in common OS firewalls. Cloud provider firewalls are separate.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 22/tcp || say 'WARNING: ufw could not allow port 22.'
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=22/tcp && firewall-cmd --reload || say 'WARNING: firewalld could not allow port 22.'
fi

# Apply settings: socket(s), then whichever ssh service the image uses.
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || fail "systemctl daemon-reload failed; run bash '$BACKUP/rollback.sh'"
  for unit in "${SOCKET_UNITS[@]}"; do
    systemctl restart "$unit" || fail "Could not restart $unit; rollback with bash '$BACKUP/rollback.sh'"
  done
  ACTIVE_SERVICE=''
  for unit in ssh.service sshd.service; do
    if systemctl is-active --quiet "$unit"; then ACTIVE_SERVICE="$unit"; break; fi
  done
  if [[ -n "$ACTIVE_SERVICE" ]]; then
    systemctl reload "$ACTIVE_SERVICE" || systemctl restart "$ACTIVE_SERVICE" || fail "SSH restart failed; run bash '$BACKUP/rollback.sh'"
  elif [[ ${#SOCKET_UNITS[@]} -eq 0 ]]; then
    systemctl start ssh.service 2>/dev/null || systemctl start sshd.service || fail 'Could not start OpenSSH service.'
  fi
elif command -v service >/dev/null 2>&1; then
  service ssh reload || service sshd reload || fail 'Could not reload the SSH service.'
else
  fail 'OpenSSH config updated, but no known init/service manager was found; reload sshd manually.'
fi

if command -v ss >/dev/null 2>&1; then
  if ! ss -H -lnt '( sport = :22 )' | grep -q .; then
    say 'WARNING: No local TCP/22 listener detected. Check systemd socket, firewalls, and service status.'
  fi
fi
say 'Configured SSH: TCP 22, root public-key login, passwords disabled.'
say "Backups + rollback: $BACKUP/rollback.sh"
say 'BEFORE closing this connection, open a NEW terminal and test key login on port 22.'
say 'Also ensure your datacenter/provider firewall allows inbound TCP port 22.'
