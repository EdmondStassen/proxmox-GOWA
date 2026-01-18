#!/usr/bin/env bash
# Proxmox Notes Helper - Proxmox Helper Include
#
# Goal:
# - Notes standaard cleanen bij start (na build_container, zodra CTID bestaat)
# - Daarna: elke keer dat je iets wilt wegschrijven -> APPEND via vaste structuur
#
# Belangrijk ontwerp:
# - We vermijden "get notes" volledig door een interne buffer (NOTES_ACCUM) bij te houden.
#   Proxmox (pct set --description) kan niet echt appenden; dus we bouwen zelf de tekst op
#   en schrijven telkens de volledige buffer weg.
#
# Requirements:
# - build.func moet al gesourced zijn (voor msg_info/msg_ok/etc.)
# - CTID moet bestaan voordat je init/append doet

# USE THE FOLLOWING CODE TO INCLUDE AND EXECUTE THIS BASH SCRIPT (without END COMMENT lines)
: <<'END_COMMENT'
# ------------------------------------------------------------------
# Notes helper include (SELF-CONTAINED BLOCK)
# ------------------------------------------------------------------
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/main/includes/notes.include.sh"
source <(curl -fsSL "$SOURCEURL")
unset SOURCEURL

# ... vóór build_container kun je al notes content voorbereiden, maar init pas NA build_container

build_container

# Clean notes once (optioneel met header)
notes::init "Provisioning notes for ${APP} (CTID ${CTID})"

# Standaard structuur: NOTE_MSG opbouwen en daarna notes::append_msg
NOTE_MSG="$(cat <<EOF
OK: Docker installed
EOF
)"
notes::append_msg

# Of direct:
notes::append "$(cat <<EOF
Networking:
- LXC IP: ${LXC_IP}
EOF
)"
# ------------------------------------------------------------------
END_COMMENT

# ---------------- internals ----------------
notes::__strip_ansi() {
  sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'
}

notes::__require_ctid() {
  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not set; run build_container before using notes::init/notes::append"
    return 1
  fi
  return 0
}

notes::__set_description() {
  # Writes NOTES_ACCUM to Proxmox description
  local content="${1:-}"
  content="$(printf '%s' "$content" | notes::__strip_ansi)"
  pct set "$CTID" --description "$content" >/dev/null
}

# ---------------- public API ----------------

# notes::init [header]
# - Cleans notes once (overwrites existing description)
# - Initializes internal buffer NOTES_ACCUM
notes::init() {
  notes::__require_ctid || return 1

  local header="${1:-}"
  if [[ -n "$header" ]]; then
    export NOTES_ACCUM
    NOTES_ACCUM="$(printf '%s' "$header" | notes::__strip_ansi)"
  else
    export NOTES_ACCUM
    NOTES_ACCUM=""
  fi

  msg_info "Cleaning Proxmox Notes"
  notes::__set_description "$NOTES_ACCUM"
  msg_ok "Notes cleaned"
}

# notes::append "block text"
# - Appends to internal buffer (NOTES_ACCUM) and writes back to Proxmox
notes::append() {
  notes::__require_ctid || return 1

  local block="${1:-}"
  block="$(printf '%s' "$block" | notes::__strip_ansi)"

  # If init not called yet, we still behave sensibly:
  # start from empty (and clean once implicitly)
  if [[ -z "${NOTES_ACCUM+x}" ]]; then
    export NOTES_ACCUM=""
  fi

  if [[ -z "$NOTES_ACCUM" ]]; then
    NOTES_ACCUM="$block"
  else
    NOTES_ACCUM="${NOTES_ACCUM}"$'\n\n'"${block}"
  fi

  notes::__set_description "$NOTES_ACCUM"
}

# notes::append_msg
# - Uses NOTE_MSG variable, then unsets it
# Pattern:
#   NOTE_MSG="$(cat <<EOF ... EOF)"; notes::append_msg
notes::append_msg() {
  if [[ -z "${NOTE_MSG+x}" ]]; then
    msg_error "NOTE_MSG is not set; build NOTE_MSG first, then call notes::append_msg"
    return 1
  fi
  notes::append "$NOTE_MSG"
  unset NOTE_MSG
}

# notes::append_kv "Title" "Value"
# - Convenience helper for single line items
notes::append_kv() {
  local k="${1:-}"
  local v="${2:-}"
  notes::append "${k}: ${v}"
}
