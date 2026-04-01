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

  iface="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1; exit}')"
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

  return 1
}

detect_tray_binary() {
  if has_cmd nm-applet; then
    printf 'nm-applet\n'
    return 0
  fi

  if has_cmd nm-tray; then
    printf 'nm-tray\n'
    return 0
  fi

  return 1
}

tray_exec_line() {
  local tray_bin="$1"

  case "$tray_bin" in
    nm-applet) printf 'nm-applet --indicator\n' ;;
    nm-tray) printf 'nm-tray\n' ;;
    *) return 1 ;;
  esac
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
  local tray_bin

  iface="$(detect_wifi_iface || true)"
  tray_bin="$(detect_tray_binary || true)"

  log "Status do NetworkManager"
  systemctl is-enabled NetworkManager || true
  systemctl is-active NetworkManager || true

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

  if [[ -n "$tray_bin" ]]; then
    log "Cliente de tray disponível: $tray_bin"
  else
    warn "Nenhum cliente de tray encontrado (nm-applet ou nm-tray)"
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

  if root_cmd systemctl list-unit-files iwd.service --no-legend | awk '{print $1}' | grep -q '^iwd.service$'; then
    log "Desabilitando iwd.service para evitar conflitos com o backend padrão do NetworkManager"
    root_cmd systemctl disable --now iwd.service || true
  fi

  if [[ "$changed" -eq 1 ]]; then
    root_cmd systemctl daemon-reload
  fi
}

ensure_selfheal_service() {
  local service_changed=0

  root_cmd install -m 0755 "$SCRIPT_PATH" "$INSTALLED_SCRIPT_PATH"

  if ! root_cmd test -f "$SELFHEAL_SERVICE_PATH"; then
    service_changed=1
  fi

  root_cmd tee "$SELFHEAL_SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Auto recuperação do Wi-Fi e indicador do NetworkManager
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=${INSTALLED_SCRIPT_PATH} --self-heal

[Install]
WantedBy=multi-user.target
EOF

  service_changed=1

  if [[ "$service_changed" -eq 1 ]]; then
    root_cmd systemctl daemon-reload
  fi

  root_cmd systemctl enable "$SELFHEAL_SERVICE_NAME" >/dev/null
}

ensure_tray_binary() {
  local tray_bin

  tray_bin="$(detect_tray_binary || true)"
  if [[ -n "$tray_bin" ]]; then
    printf '%s\n' "$tray_bin"
    return 0
  fi

  if ! has_cmd apt-get; then
    return 1
  fi

  log "Instalando cliente de tray do NetworkManager (network-manager-gnome)"
  ensure_apt_updated_once
  root_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager-gnome

  tray_bin="$(detect_tray_binary || true)"
  if [[ -n "$tray_bin" ]]; then
    printf '%s\n' "$tray_bin"
    return 0
  fi

  return 1
}

ensure_tray_autostart() {
  local target_user="$1"
  local tray_bin="$2"
  local tray_exec
  local user_home
  local autostart_dir
  local autostart_file

  tray_exec="$(tray_exec_line "$tray_bin")"

  user_home="$(getent passwd "$target_user" | cut -d: -f6)"
  [[ -n "$user_home" ]] || {
    warn "não consegui descobrir o HOME do usuário $target_user"
    return 1
  }

  autostart_dir="$user_home/.config/autostart"
  autostart_file="$autostart_dir/fix-wifi-networkmanager-tray.desktop"

  log "Configurando autostart do tray para o usuário $target_user"
  root_cmd mkdir -p "$autostart_dir"
  root_cmd tee "$autostart_file" > /dev/null <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=NetworkManager tray
Comment=Inicia automaticamente o indicador de Wi-Fi
Exec=$tray_exec
X-GNOME-Autostart-enabled=true
Terminal=false
EOF

  root_cmd chown "$target_user:$target_user" "$autostart_file"
}

restart_wifi_stack() {
  local iface="$1"

  log "Desbloqueando rádio Wi-Fi"
  root_cmd rfkill unblock wifi || true

  log "Habilitando e reiniciando NetworkManager"
  root_cmd systemctl enable NetworkManager >/dev/null
  root_cmd systemctl restart NetworkManager

  log "Ativando Wi-Fi e forçando scan"
  nmcli radio wifi on
  nmcli device set "$iface" managed yes || true
  nmcli device wifi rescan ifname "$iface" || true
  sleep 2

  # Reusa perfis já conhecidos quando disponíveis.
  nmcli device connect "$iface" || true
}

restart_tray_indicator_for_session() {
  local tray_bin="$1"
  local target_user="$2"
  local uid runtime_dir display_env wayland_env xauth_env

  uid="$(id -u "$target_user")"
  runtime_dir="/run/user/$uid"
  display_env="${DISPLAY:-}"
  wayland_env="${WAYLAND_DISPLAY:-}"
  xauth_env="${XAUTHORITY:-}"

  if [[ -z "$display_env" && -z "$wayland_env" ]]; then
    warn "sem sessão gráfica neste shell, o tray será iniciado automaticamente no próximo login"
    return 0
  fi

  log "Reiniciando indicador de Wi-Fi na sessão atual"

  case "$tray_bin" in
    nm-applet)
      run_as_user "$target_user" env \
        DISPLAY="$display_env" \
        WAYLAND_DISPLAY="$wayland_env" \
        XAUTHORITY="$xauth_env" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        bash -lc 'pkill -x nm-applet || true; nohup nm-applet --indicator >/dev/null 2>&1 &'
      ;;
    nm-tray)
      run_as_user "$target_user" env \
        DISPLAY="$display_env" \
        WAYLAND_DISPLAY="$wayland_env" \
        XAUTHORITY="$xauth_env" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        bash -lc 'pkill -x nm-tray || true; nohup nm-tray >/dev/null 2>&1 &'
      ;;
    *)
      warn "cliente de tray não suportado: $tray_bin"
      ;;
  esac
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
    warn "Em redes novas, selecione a rede no tray e informe senha uma vez para salvar o perfil"
  fi
}

bootstrap_full_fix() {
  local iface
  local tray_bin
  local target_user

  install_package_if_missing nmcli network-manager
  install_package_if_missing rfkill rfkill
  install_package_if_missing iw iw
  install_package_if_missing systemctl systemd

  cleanup_old_fix_and_conflicts
  ensure_selfheal_service

  iface="$(detect_wifi_iface || true)"
  [[ -n "$iface" ]] || die "nenhuma interface Wi-Fi detectada"

  restart_wifi_stack "$iface"

  target_user="$(detect_target_user || true)"
  if [[ -n "$target_user" ]]; then
    tray_bin="$(ensure_tray_binary || true)"
    if [[ -n "$tray_bin" ]]; then
      ensure_tray_autostart "$target_user" "$tray_bin" || true
      restart_tray_indicator_for_session "$tray_bin" "$target_user" || true
    else
      warn "não foi possível instalar/achar cliente de tray automaticamente"
    fi
  else
    warn "não consegui detectar usuário de desktop para configurar autostart do tray"
  fi

  report_result "$iface"
}

run_self_heal() {
  local iface

  has_cmd nmcli || die "nmcli não encontrado, rode o script sem parâmetros para bootstrap completo"
  has_cmd rfkill || die "rfkill não encontrado, rode o script sem parâmetros para bootstrap completo"

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
