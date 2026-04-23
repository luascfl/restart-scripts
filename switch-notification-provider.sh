#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APT_UPDATED=0

SYSTEM_LXQT_AUTOSTART="/etc/xdg/autostart/lxqt-notifications.desktop"
USER_AUTOSTART_DIR="${HOME}/.config/autostart"
USER_LXQT_AUTOSTART="${USER_AUTOSTART_DIR}/lxqt-notifications.desktop"
USER_DUNST_AUTOSTART="${USER_AUTOSTART_DIR}/dunst.desktop"

log() {
  printf '[notify-switch] %s\n' "$*"
}

warn() {
  printf '[notify-switch] aviso: %s\n' "$*" >&2
}

die() {
  printf '[notify-switch] erro: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Uso:
  ${SCRIPT_NAME} --to-dunst   instala e ativa dunst no LXQt
  ${SCRIPT_NAME} --to-lxqt    restaura lxqt-notificationd
  ${SCRIPT_NAME} --status     mostra o daemon ativo via DBus
  ${SCRIPT_NAME} --help       mostra esta ajuda

Sem argumento, o padrão é --to-dunst.
EOF
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

root_cmd() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
    return
  fi

  if has_cmd sudo; then
    sudo "$@"
    return
  fi

  die "este passo precisa de root e sudo não está disponível"
}

ensure_user_session_context() {
  if [[ ${EUID} -eq 0 ]]; then
    die "execute este script como usuário normal, sem sudo"
  fi

  if [[ -z "${XDG_CURRENT_DESKTOP:-}" ]]; then
    warn "XDG_CURRENT_DESKTOP vazio, continuo mesmo assim"
  elif [[ "${XDG_CURRENT_DESKTOP}" != *LXQt* ]]; then
    warn "desktop atual não parece LXQt (${XDG_CURRENT_DESKTOP}), continuo mesmo assim"
  fi
}

ensure_apt_updated_once() {
  if [[ ${APT_UPDATED} -eq 1 ]]; then
    return
  fi

  log "Atualizando índice de pacotes do apt"
  root_cmd apt-get update
  APT_UPDATED=1
}

install_dunst_if_missing() {
  if has_cmd dunst; then
    return
  fi

  has_cmd apt-get || die "apt-get não está disponível para instalar dunst"
  ensure_apt_updated_once

  log "Instalando dunst"
  root_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y dunst

  has_cmd dunst || die "dunst não ficou disponível após instalação"
}

ensure_autostart_dir() {
  mkdir -p "${USER_AUTOSTART_DIR}"
}

set_desktop_key() {
  local file_path="$1"
  local key="$2"
  local value="$3"

  if grep -q "^${key}=" "${file_path}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file_path}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file_path}"
  fi
}

disable_lxqt_autostart_for_user() {
  ensure_autostart_dir

  if [[ -f "${SYSTEM_LXQT_AUTOSTART}" && ! -f "${USER_LXQT_AUTOSTART}" ]]; then
    cp "${SYSTEM_LXQT_AUTOSTART}" "${USER_LXQT_AUTOSTART}"
  elif [[ ! -f "${USER_LXQT_AUTOSTART}" ]]; then
    cat > "${USER_LXQT_AUTOSTART}" <<EOF
[Desktop Entry]
Type=Application
Name=Notification Daemon
Exec=lxqt-notificationd
OnlyShowIn=LXQt;
EOF
  fi

  set_desktop_key "${USER_LXQT_AUTOSTART}" "Hidden" "true"
  set_desktop_key "${USER_LXQT_AUTOSTART}" "X-GNOME-Autostart-enabled" "false"
}

enable_lxqt_autostart_for_user() {
  ensure_autostart_dir

  if [[ -f "${SYSTEM_LXQT_AUTOSTART}" && ! -f "${USER_LXQT_AUTOSTART}" ]]; then
    cp "${SYSTEM_LXQT_AUTOSTART}" "${USER_LXQT_AUTOSTART}"
  elif [[ ! -f "${USER_LXQT_AUTOSTART}" ]]; then
    cat > "${USER_LXQT_AUTOSTART}" <<EOF
[Desktop Entry]
Type=Application
Name=Notification Daemon
Exec=lxqt-notificationd
OnlyShowIn=LXQt;
EOF
  fi

  set_desktop_key "${USER_LXQT_AUTOSTART}" "Hidden" "false"
  set_desktop_key "${USER_LXQT_AUTOSTART}" "X-GNOME-Autostart-enabled" "true"
}

write_dunst_autostart() {
  ensure_autostart_dir

  cat > "${USER_DUNST_AUTOSTART}" <<'EOF'
[Desktop Entry]
Type=Application
Name=Dunst Notification Daemon
Exec=dunst
OnlyShowIn=LXQt;
X-GNOME-Autostart-enabled=true
Hidden=false
EOF
}

disable_dunst_autostart() {
  rm -f "${USER_DUNST_AUTOSTART}"
}

start_dunst_now() {
  pkill -x lxqt-notificationd || true
  pkill -x dunst || true

  nohup dunst >/dev/null 2>&1 &
  sleep 1

  if pgrep -x dunst >/dev/null 2>&1; then
    log "dunst ativo na sessão atual"
  else
    warn "não consegui confirmar dunst em execução"
  fi
}

start_lxqt_now() {
  pkill -x dunst || true
  pkill -x lxqt-notificationd || true

  nohup lxqt-notificationd >/dev/null 2>&1 &
  sleep 1

  if pgrep -x lxqt-notificationd >/dev/null 2>&1; then
    log "lxqt-notificationd ativo na sessão atual"
  else
    warn "não consegui confirmar lxqt-notificationd em execução"
  fi
}

show_status() {
  if ! has_cmd gdbus; then
    warn "gdbus não está disponível"
    return
  fi

  local info
  if info="$(gdbus call --session \
      --dest org.freedesktop.Notifications \
      --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.GetServerInformation 2>/dev/null)"; then
    log "servidor de notificações atual: ${info}"
  else
    warn "não consegui ler o servidor de notificações via DBus"
  fi
}

switch_to_dunst() {
  ensure_user_session_context
  install_dunst_if_missing
  disable_lxqt_autostart_for_user
  write_dunst_autostart
  start_dunst_now
  show_status

  log "troca concluída, no próximo login o dunst será iniciado automaticamente"
}

switch_to_lxqt() {
  ensure_user_session_context
  disable_dunst_autostart
  enable_lxqt_autostart_for_user
  start_lxqt_now
  show_status

  log "restauração concluída, no próximo login o lxqt-notificationd será iniciado automaticamente"
}

main() {
  local mode="${1:---to-dunst}"

  case "${mode}" in
    --to-dunst)
      switch_to_dunst
      ;;
    --to-lxqt)
      switch_to_lxqt
      ;;
    --status)
      show_status
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage
      die "opção inválida: ${mode}"
      ;;
  esac
}

main "$@"
