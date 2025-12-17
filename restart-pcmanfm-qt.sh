#!/usr/bin/env bash
set -euo pipefail

# Encerra qualquer pcmanfm-qt e tenta abrir uma nova janela, gravando log para depuração.
target_dir="${1:-$HOME}"
log_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
log_file="$log_dir/pcmanfm-qt-restart.log"
mkdir -p "$log_dir"

# Evita log infinito: se o arquivo passar de 5 MB, arquiva.
if [[ -f "$log_file" ]] && [[ $(stat -c%s "$log_file") -gt 5242880 ]]; then
  mv -f "$log_file" "$log_file.old" || true
fi
: >"$log_file"

echo "[$(date)] Reiniciando pcmanfm-qt em '$target_dir'" >>"$log_file"

display="${DISPLAY:-}"
if [[ -z "$display" ]]; then
  echo "DISPLAY não definido; exporte DISPLAY=:0 ou inicie um servidor gráfico." | tee -a "$log_file"
  exit 1
fi

x_socket="/tmp/.X11-unix/X${display#:}"
if [[ ! -S "$x_socket" ]]; then
  echo "Socket X '$x_socket' não existe ou sem permissão; o servidor gráfico não está acessível." | tee -a "$log_file"
  exit 1
fi

if [[ -n "${XAUTHORITY:-}" && ! -r "$XAUTHORITY" ]]; then
  echo "XAUTHORITY definido para '$XAUTHORITY' mas não é legível; ajuste permissões ou unset XAUTHORITY." | tee -a "$log_file"
fi

echo "Matando instâncias antigas..." | tee -a "$log_file"
pkill -u "$USER" -x pcmanfm-qt >/dev/null 2>&1 || true
sleep 1
pkill -9 -u "$USER" -x pcmanfm-qt >/dev/null 2>&1 || true

if ! command -v pcmanfm-qt >/dev/null 2>&1; then
  echo "pcmanfm-qt não encontrado no PATH." | tee -a "$log_file"
  exit 1
fi

qt_debug_env=()
if [[ "${DEBUG_PCMANFM_QT:-0}" == "1" ]]; then
  qt_debug_env=(QT_DEBUG_PLUGINS=1 QT_LOGGING_RULES="qt.*.debug=true")
  echo "DEBUG_PCMANFM_QT=1 -> log verboso habilitado" >>"$log_file"
fi

echo "Abrindo pcmanfm-qt..." | tee -a "$log_file"
nohup env "${qt_debug_env[@]}" \
  pcmanfm-qt --new-window --profile=lxqt "$target_dir" >>"$log_file" 2>&1 &
pid=$!
sleep 3

if kill -0 "$pid" >/dev/null 2>&1; then
  echo "Processo $pid está rodando; janela deve abrir. Log em $log_file"
  exit 0
fi

echo "pcmanfm-qt não subiu; tentando fallback com pcmanfm-qt sem flags" | tee -a "$log_file"
nohup env "${qt_debug_env[@]}" \
  pcmanfm-qt "$target_dir" >>"$log_file" 2>&1 &
pid=$!
sleep 3

if kill -0 "$pid" >/dev/null 2>&1; then
  echo "Processo $pid está rodando (sem flags); janela deve abrir. Log em $log_file"
  exit 0
fi

echo "Ainda não subiu; tentando fallback com xdg-open" | tee -a "$log_file"
nohup xdg-open "$target_dir" >>"$log_file" 2>&1 &
echo "Cheque $log_file para erros capturados."
exit 1
