#!/bin/bash

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Determinar usuário real (caso esteja rodando com sudo)
REAL_USER=${SUDO_USER:-$USER}
REAL_UID=$(id -u "$REAL_USER")
export XDG_RUNTIME_DIR="/run/user/$REAL_UID"

# Função helper para rodar comandos systemctl --user como o usuário real
user_systemctl() {
    if [ "$USER" = "root" ]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

status() {
    echo -e "${YELLOW}--- Interface (User Service) ---${NC}"
    if user_systemctl is-active --quiet warp-taskbar; then
        echo -e "${GREEN}ATIVO${NC} (via systemd --user)"
    else
        echo -e "${RED}INATIVO${NC}"
    fi

    echo -e "${YELLOW}--- Daemon (System Service) ---${NC}"
    if systemctl is-active --quiet warp-svc; then
        echo -e "${GREEN}ATIVO${NC}"
    else
        echo -e "${RED}INATIVO${NC}"
    fi
    
    echo -e "${YELLOW}--- Conexão ---${NC}"
    if ip addr | grep -q "CloudflareWARP"; then
         echo -e "${GREEN}CONECTADO${NC}"
    else
         echo -e "${RED}DESCONECTADO${NC}"
    fi
}

case "$1" in
    off)
        echo -e "${RED}🛑 Desativando Cloudflare WARP...${NC}"
        
        # 1. Desconectar VPN
        if command -v warp-cli &> /dev/null; then
            warp-cli disconnect > /dev/null 2>&1
        fi
        
        # 2. Parar Serviço de Usuário (Taskbar) - O culpado pela reinicialização!
        echo "Parando warp-taskbar (user)..."
        user_systemctl stop warp-taskbar
        user_systemctl disable warp-taskbar > /dev/null 2>&1
        
        # 3. Parar Serviço do Sistema (Daemon)
        echo "Parando warp-svc (system)..."
        if [ "$USER" != "root" ]; then
            sudo systemctl stop warp-svc
            sudo systemctl disable warp-svc > /dev/null 2>&1
        else
            systemctl stop warp-svc
            systemctl disable warp-svc > /dev/null 2>&1
        fi
        
        # 4. Verificação de segurança
        if pgrep -f warp > /dev/null; then
             echo "Limpando processos teimosos..."
             pkill -9 -f warp 2>/dev/null || sudo pkill -9 -f warp
        fi
        
        echo -e "${GREEN}Desativado com sucesso.${NC}"
        ;;
        
    on)
        echo -e "${GREEN}🟢 Ativando Cloudflare WARP...${NC}"
        
        # 1. Iniciar Serviço do Sistema
        echo "Iniciando warp-svc (system)..."
        if [ "$USER" != "root" ]; then
            sudo systemctl enable --now warp-svc
        else
            systemctl enable --now warp-svc
        fi
        
        echo "Aguardando..."
        sleep 2
        
        # 2. Iniciar Serviço de Usuário
        echo "Iniciando warp-taskbar (user)..."
        user_systemctl enable --now warp-taskbar
        
        # 3. Conectar
        echo "Conectando VPN..."
        warp-cli connect
        ;;
        
    status)
        status
        ;;
        
    *)
        echo "Uso: $0 {off|on|status}"
        exit 1
        ;;
esac
