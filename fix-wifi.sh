#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0")"
SELFHEAL_SERVICE_NAME="fix-wifi-selfheal.service"
SELFHEAL_SERVICE_PATH="/etc/systemd/system/${SELFHEAL_SERVICE_NAME}"
INSTALLED_SCRIPT_PATH="/usr/local/sbin/fix-wifi"
APT_UPDATED=0

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
  $SCRIPT_NAME                 bootstrap completo e correção permanente
  $SCRIPT_NAME --fix           igual ao padrão
  $SCRIPT_NAME --self-heal     só auto recuperação da stack de rede
  $SCRIPT_NAME --status        mostra status atual sem alterar nada
  $SCRIPT_NAME --help          mostra esta ajuda
EOF
}

has_cmd() {
  command -v "$1" >/dev/null
}

root_cmd() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
    return
  fi

  if has_cmd sudo; then
    sudo "$@"
    return
  fi

  die "este passo precisa de root e sudo não está disponível"
}

run_as_user() {
  local target_user="$1"
  shift

  if [[ "$(id -un)" == "$target_user" ]]; then
    "$@"
    return
  fi

  if has_cmd sudo; then
    sudo -u "$target_user" "$@"
    return
  fi

  if has_cmd runuser; then
    runuser -u "$target_user" -- "$@"
    return
  fi

  die "não consegui executar comando como usuário $target_user"
}

ensure_apt_updated_once() {
  if [[ "$APT_UPDATED" -eq 1 ]]; then
    return
  fi

  log "Atualizando índice de pacotes (apt)"
  root_cmd apt-get update
  APT_UPDATED=1
}

install_package_if_missing() {
  local cmd_name="$1"
  local package_name="$2"

  if has_cmd "$cmd_name"; then
    return
  fi

  has_cmd apt-get || die "falta '$cmd_name' e apt-get não está disponível para instalar '$package_name'"

  log "Instalando pacote obrigatório: $package_name"
  ensure_apt_updated_once
  root_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name"

  has_cmd "$cmd_name" || die "instalação de '$package_name' não disponibilizou '$cmd_name'"
}

detect_wifi_iface() {
  local iface

  iface="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1; exit}')"
  if [[ -n "$iface" ]]; then
    printf '%s\n' "$iface"
    return 0
  fi

  if has_cmd iw; then
    iface="$(iw dev | awk '$1=="Interface" {print $2; exit}')"
    if [[ -n "$iface" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  fi

  iface="$(ls /sys/class/net/ | grep -E '^wl' | head -1)"
  if [[ -n "$iface" ]]; then
    printf '%s\n' "$iface"
    return 0
  fi

  return 1
}

detect_target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi

  if [[ -n "${USER:-}" && "${USER}" != "root" ]]; then
    printf '%s\n' "$USER"
    return 0
  fi

  awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd
}

show_status() {
  local iface

  iface="$(detect_wifi_iface || true)"

  log "Status do NetworkManager"
  systemctl is-enabled NetworkManager || true
  systemctl is-active NetworkManager || true

  log "Status do iwd"
  systemctl is-enabled iwd || true
  systemctl is-active iwd || true

  log "Status do serviço de auto recuperação"
  systemctl is-enabled "$SELFHEAL_SERVICE_NAME" || true
  systemctl is-active "$SELFHEAL_SERVICE_NAME" || true

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

remove_wifi_backend_iwd_from_file() {
  local file_path="$1"

  if ! root_cmd test -f "$file_path"; then
    return
  fi

  if root_cmd grep -q '^[[:space:]]*wifi\.backend=iwd[[:space:]]*$' "$file_path"; then
    log "Removendo wifi.backend=iwd de $file_path"
    root_cmd sed -i '/^[[:space:]]*wifi\.backend=iwd[[:space:]]*$/d' "$file_path"
  fi
}

fix_tray_duplicates() {
  # Desabilita nm-applet do sistema — Lubuntu usa nm-tray nativamente
  if [[ -f /etc/xdg/autostart/nm-applet.desktop ]]; then
    log "Desabilitando nm-applet duplicado do sistema"
    root_cmd mv /etc/xdg/autostart/nm-applet.desktop \
                /etc/xdg/autostart/nm-applet.desktop.bak || true
  fi

  # Remove autostart do tray criado por versões anteriores do script
  local target_user
  target_user="$(detect_target_user || true)"
  if [[ -n "$target_user" ]]; then
    local user_home
    user_home="$(getent passwd "$target_user" | cut -d: -f6)"
    local autostart_file="$user_home/.config/autostart/fix-wifi-networkmanager-tray.desktop"
    if [[ -f "$autostart_file" ]]; then
      log "Removendo autostart legado do tray"
      rm -f "$autostart_file"
    fi
  fi

  # Mata instâncias duplicadas na sessão atual
  pkill -x nm-applet || true
}

cleanup_old_fix_and_conflicts() {
  local changed=0
  local conf_file

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

  remove_wifi_backend_iwd_from_file /etc/NetworkManager/NetworkManager.conf

  if root_cmd test -d /etc/NetworkManager/conf.d; then
    while IFS= read -r conf_file; do
      remove_wifi_backend_iwd_from_file "$conf_file"
    done < <(root_cmd find /etc/NetworkManager/conf.d -maxdepth 1 -type f -name '*.conf' -print)
  fi

  # Garante que iwd está ativo — necessário para o driver iwlwifi neste kernel
  log "Garantindo que iwd está ativo como backend de Wi-Fi"
  root_cmd systemctl enable iwd.service || true
  root_cmd systemctl start iwd.service || true

  if [[ "$changed" -eq 1 ]]; then
    root_cmd systemctl daemon-reload
  fi
}

ensure_selfheal_service() {
  root_cmd install -m 0755 "$SCRIPT_PATH" "$INSTALLED_SCRIPT_PATH"

  root_cmd tee "$SELFHEAL_SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Auto recuperação do Wi-Fi e indicador do NetworkManager
After=iwd.service NetworkManager.service
Wants=iwd.service NetworkManager.service

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'until iwctl station wlan0 show 2>/dev/null | grep -q "connected"; do sleep 2; done'
ExecStart=${INSTALLED_SCRIPT_PATH} --self-heal

[Install]
WantedBy=multi-user.target
EOF

  root_cmd systemctl daemon-reload
  root_cmd systemctl enable "$SELFHEAL_SERVICE_NAME" >/dev/null
}

restart_wifi_stack() {
  local iface="$1"

  log "Desbloqueando rádio Wi-Fi"
  root_cmd rfkill unblock wifi || true

  log "Reiniciando iwd"
  root_cmd systemctl restart iwd.service
  sleep 5

  log "Aguardando iwd conectar..."
  local attempts=0
  while ! iwctl station "$iface" show 2>/dev/null | grep -q "connected"; do
    sleep 2
    attempts=$((attempts + 1))
    if [[ $attempts -ge 15 ]]; then
      warn "iwd não conectou em 30s — continuando assim mesmo"
      break
    fi
  done

  log "Rodando dhcpcd para garantir IP e rota"
  root_cmd dhcpcd "$iface" || true
  sleep 5

  log "Habilitando e reiniciando NetworkManager"
  root_cmd systemctl enable NetworkManager >/dev/null
  root_cmd systemctl restart NetworkManager
  sleep 5

  nmcli radio wifi on || true
  nmcli device set "$iface" managed yes || true
}

report_result() {
  local iface="$1"
  local state ip4

  state="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v iface="$iface" '$1==iface {print $2; exit}')"
  ip4="$(nmcli -g IP4.ADDRESS device show "$iface" 2>/dev/null | awk 'NF {print; exit}')"

  printf '\n'
  log "Estado final da interface $iface: ${state:-desconhecido}"

  if [[ -n "$ip4" ]]; then
    log "IP obtido: $ip4"
    ping -c 2 8.8.8.8 > /dev/null 2>&1 && log "Internet OK" || warn "sem rota para internet"
    ping -c 2 google.com > /dev/null 2>&1 && log "DNS OK" || warn "DNS falhou"
  else
    warn "Sem IP — em redes novas, selecione a rede no tray e informe a senha uma vez para salvar o perfil"
  fi
}

bootstrap_full_fix() {
  local iface

  install_package_if_missing nmcli network-manager
  install_package_if_missing rfkill rfkill
  install_package_if_missing iw iw
  install_package_if_missing dhcpcd dhcpcd

  fix_tray_duplicates
  cleanup_old_fix_and_conflicts
  ensure_selfheal_service

  iface="$(detect_wifi_iface || true)"
  [[ -n "$iface" ]] || die "nenhuma interface Wi-Fi detectada"

  restart_wifi_stack "$iface"
  report_result "$iface"
}

run_self_heal() {
  local iface

  has_cmd nmcli || die "nmcli não encontrado, rode o script sem parâmetros para bootstrap completo"
  has_cmd rfkill || die "rfkill não encontrado, rode o script sem parâmetros para bootstrap completo"

  fix_tray_duplicates
  cleanup_old_fix_and_conflicts

  iface="$(detect_wifi_iface || true)"
  [[ -n "$iface" ]] || die "nenhuma interface Wi-Fi detectada"

  restart_wifi_stack "$iface"
  report_result "$iface"
}

main() {
  local mode

  mode="${1:---fix}"

  case "$mode" in
    --help|-h)
      usage
      exit 0
      ;;
    --status)
      has_cmd nmcli || die "nmcli não encontrado"
      has_cmd systemctl || die "systemctl não encontrado"
      show_status
      exit 0
      ;;
    --self-heal)
      run_self_heal
      exit 0
      ;;
    --fix|--bootstrap|"")
      bootstrap_full_fix
      exit 0
      ;;
    *)
      die "opção inválida: $mode"
      ;;
  esac
}

main "$@"
