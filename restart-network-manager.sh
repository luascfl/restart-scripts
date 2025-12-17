#!/usr/bin/env bash
set -euo pipefail

# Reinicia o NetworkManager com os comandos disponíveis no sistema.
declare -a restart_cmd=()

if command -v systemctl >/dev/null 2>&1; then
  restart_cmd=(sudo systemctl restart NetworkManager)
elif command -v service >/dev/null 2>&1; then
  # Em algumas distros o serviço se chama NetworkManager, em outras network-manager.
  if service --status-all 2>/dev/null | grep -qi "NetworkManager"; then
    restart_cmd=(sudo service NetworkManager restart)
  else
    restart_cmd=(sudo service network-manager restart)
  fi
fi

if [[ ${#restart_cmd[@]} -eq 0 ]]; then
  echo "Não encontrei systemctl ou service para reiniciar o NetworkManager." >&2
  exit 1
fi

echo "Reiniciando NetworkManager..."
if "${restart_cmd[@]}"; then
  echo "NetworkManager reiniciado com sucesso."
else
  echo "Falha ao reiniciar o NetworkManager." >&2
  exit 1
fi

# Dá um toggle no Wi‑Fi para garantir que volte ativo.
if command -v nmcli >/dev/null 2>&1; then
  nmcli radio wifi off >/dev/null 2>&1 || true
  sleep 1
  nmcli radio wifi on >/dev/null 2>&1 || true
fi
