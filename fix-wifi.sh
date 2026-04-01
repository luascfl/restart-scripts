#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

log() {
  printf '[fix-wifi] %s\n' "$*"
}

warn() {
  printf '[fix-wifi] aviso: %s\n' "$*" >&2
}

die() {
  printf '[fix-wifi] erro: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Uso:
  $SCRIPT_NAME            aplica o fix permanente do Wi-Fi/tray
  $SCRIPT_NAME --status   mostra status atual do Wi-Fi/tray sem alterar nada
  $SCRIPT_NAME --help     mostra esta ajuda
EOF
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null || die "comando obrigatório não encontrado: $cmd"
}

root_cmd() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_as_user() {
  local user="$1"
  shift

  if [[ "$(id -un)" == "$user" ]]; then
    "$@"
  else
    sudo -u "$user" "$@"
  fi
}

detect_wifi_iface() {
  local iface

  iface="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1; exit}')"
  if [[ -n "$iface" ]]; then
    printf '%s\n' "$iface"
    return 0
  fi

  if command -v iw >/dev/null; then
    iface="$(iw dev | awk '$1=="Interface" {print $2; exit}')"
    if [[ -n "$iface" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  fi

  return 1
}

show_status() {
  local iface
  iface="$(detect_wifi_iface || true)"

  log "Status do NetworkManager"
  systemctl is-enabled NetworkManager || true
  systemctl is-active NetworkManager || true

  log "Status geral de rede"
  nmcli general status || true
  nmcli device status || true

  if [[ -n "$iface" ]]; then
    log "Detalhes da interface Wi-Fi: $iface"
    nmcli -f GENERAL.DEVICE,GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY device show "$iface" || true
  else
    warn "Nenhuma interface Wi-Fi detectada"
  fi
}

cleanup_old_fix() {
  local changed=0
  local nm_conf="/etc/NetworkManager/NetworkManager.conf"

  if root_cmd test -f /etc/systemd/system/fix-wifi-boot.service; then
    log "Removendo serviço legado fix-wifi-boot.service"
    root_cmd systemctl disable --now fix-wifi-boot.service || true
    root_cmd rm -f /etc/systemd/system/fix-wifi-boot.service
    changed=1
  fi

  if root_cmd test -f /etc/systemd/system/NetworkManager.service.d/wait-iwd.conf; then
    log "Removendo override legado wait-iwd.conf"
    root_cmd rm -f /etc/systemd/system/NetworkManager.service.d/wait-iwd.conf
    changed=1
  fi

  if root_cmd test -f "$nm_conf"; then
    if root_cmd grep -q '^[[:space:]]*wifi\.backend=iwd[[:space:]]*$' "$nm_conf"; then
      log "Removendo wifi.backend=iwd do NetworkManager.conf"
      root_cmd sed -i '/^[[:space:]]*wifi\.backend=iwd[[:space:]]*$/d' "$nm_conf"
      changed=1
    fi
  fi

  if root_cmd test -d /etc/NetworkManager/conf.d; then
    local conf_file
    while IFS= read -r conf_file; do
      if root_cmd grep -q '^[[:space:]]*wifi\.backend=iwd[[:space:]]*$' "$conf_file"; then
        log "Removendo wifi.backend=iwd de $conf_file"
        root_cmd sed -i '/^[[:space:]]*wifi\.backend=iwd[[:space:]]*$/d' "$conf_file"
        changed=1
      fi
    done < <(root_cmd find /etc/NetworkManager/conf.d -maxdepth 1 -type f -name '*.conf' -print)
  fi

  if [[ "$changed" -eq 1 ]]; then
    root_cmd systemctl daemon-reload
  fi
}

restart_wifi_stack() {
  local iface="$1"

  log "Desbloqueando rádio Wi-Fi"
  root_cmd rfkill unblock wifi || true

  log "Reiniciando NetworkManager"
  root_cmd systemctl enable NetworkManager >/dev/null
  root_cmd systemctl restart NetworkManager

  log "Ativando Wi-Fi e forçando novo scan"
  nmcli radio wifi on
  nmcli device set "$iface" managed yes || true
  nmcli device wifi rescan ifname "$iface" || true
  sleep 2

  # Tenta reconectar automaticamente a redes já salvas.
  nmcli device connect "$iface" || true
}

restart_tray_indicator() {
  local session_user uid runtime_dir display_env wayland_env xauth_env

  session_user="${SUDO_USER:-$USER}"
  uid="$(id -u "$session_user")"
  runtime_dir="/run/user/$uid"

  display_env="${DISPLAY:-}"
  wayland_env="${WAYLAND_DISPLAY:-}"
  xauth_env="${XAUTHORITY:-}"

  if [[ -z "$display_env" && -z "$wayland_env" ]]; then
    warn "Sem sessão gráfica neste shell. O tray será reiniciado no próximo login gráfico"
    return 0
  fi

  if command -v nm-applet >/dev/null; then
    log "Reiniciando nm-applet"
    run_as_user "$session_user" env \
      DISPLAY="$display_env" \
      WAYLAND_DISPLAY="$wayland_env" \
      XAUTHORITY="$xauth_env" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      bash -lc 'pkill -x nm-applet || true; nohup nm-applet --indicator >/dev/null &'
    return 0
  fi

  if command -v nm-tray >/dev/null; then
    log "Reiniciando nm-tray"
    run_as_user "$session_user" env \
      DISPLAY="$display_env" \
      WAYLAND_DISPLAY="$wayland_env" \
      XAUTHORITY="$xauth_env" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      bash -lc 'pkill -x nm-tray || true; nohup nm-tray >/dev/null &'
    return 0
  fi

  warn "Nenhum cliente de tray encontrado (nm-applet ou nm-tray)"
}

report_result() {
  local iface="$1"
  local state ip4

  state="$(nmcli -t -f DEVICE,STATE device status | awk -F: -v iface="$iface" '$1==iface {print $2; exit}')"
  ip4="$(nmcli -g IP4.ADDRESS device show "$iface" | awk 'NF {print; exit}')"

  printf '\n'
  log "Estado final da interface $iface: ${state:-desconhecido}"

  if [[ -n "$ip4" ]]; then
    log "IP obtido: $ip4"
  else
    warn "Sem IP no momento"
  fi

  if [[ "$state" != "connected" ]]; then
    warn "Fora de locais com rede salva, você precisa escolher a nova rede no ícone do tray e informar senha"
  fi
}

main() {
  local mode iface

  mode="${1:-fix}"

  case "$mode" in
    --help|-h)
      usage
      exit 0
      ;;
    --status)
      require_cmd nmcli
      show_status
      exit 0
      ;;
    fix|"")
      ;;
    *)
      die "opção inválida: $mode"
      ;;
  esac

  require_cmd nmcli
  require_cmd systemctl
  require_cmd rfkill

  iface="$(detect_wifi_iface || true)"
  [[ -n "$iface" ]] || die "nenhuma interface Wi-Fi detectada"

  log "Aplicando fix permanente para Wi-Fi/tray"
  cleanup_old_fix
  restart_wifi_stack "$iface"
  restart_tray_indicator
  report_result "$iface"

  printf '\n'
  log "Concluído"
}

main "$@"
