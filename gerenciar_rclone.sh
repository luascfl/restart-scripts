#!/bin/bash

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Função para listar serviços do rclone
get_rclone_services() {
    # Lista todos os arquivos de unidade que começam com rclone- e terminam com .service
    # Busca tanto nos ativos quanto nos inativos (mas carregados)
    systemctl --user list-units --all --no-legend --plain 'rclone-*.service' | awk '{print $1}'
}

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

start_rclone() {
    echo -e "${GREEN}Habilitando e iniciando serviços systemd do rclone...${NC}"
    
    # Obtém a lista dinâmica de serviços
    SERVICES=$(user_systemctl list-unit-files --no-legend 'rclone-*.service' | awk '{print $1}')
    
    if [ -z "$SERVICES" ]; then
        echo -e "${YELLOW}Nenhum serviço rclone-*.service encontrado no systemd do usuário.${NC}"
        return
    fi
    
    for SERVICE in $SERVICES;
    do
        echo "Iniciando $SERVICE..."
        user_systemctl enable "$SERVICE" --now
    done
    
    echo -e "${GREEN}Concluído. Verificando status...${NC}"
    sleep 2
    status
}

stop_rclone() {
    echo -e "${RED}Parando e desabilitando serviços systemd do rclone...${NC}"
    
    # Lista serviços ativos ou carregados
    SERVICES=$(user_systemctl list-units --all --no-legend --plain 'rclone-*.service' | awk '{print $1}')
    
    if [ -n "$SERVICES" ]; then
        for SERVICE in $SERVICES;
        do
            echo "Parando $SERVICE..."
            user_systemctl stop "$SERVICE"
            user_systemctl disable "$SERVICE" 2>/dev/null
        done
    else
        echo "Nenhum serviço rclone ativo encontrado."
    fi

    # Varredura de segurança para processos órfãos (caso algum tenha sido rodado manualmente fora do systemd)
    if pgrep -f "rclone mount" > /dev/null;
    then
        echo -e "${YELLOW}Processos rclone ainda detectados (fora do systemd?). Forçando limpeza...${NC}"
        pkill -f "rclone mount"
        sleep 1
        if pgrep -f "rclone mount" > /dev/null;
        then
             pkill -9 -f "rclone mount"
        fi
    fi
    
    # Limpar montagens órfãs (FUSE às vezes deixa o mountpoint preso)
    echo "Verificando pontos de montagem órfãos..."
    mount | grep rclone | awk '{print $3}' | while read -r MOUNTPOINT;
    do
        echo "Desmontando forçado: $MOUNTPOINT"
        fusermount -u "$MOUNTPOINT" 2>/dev/null || sudo umount -l "$MOUNTPOINT" 2>/dev/null
    done

    echo -e "${GREEN}Todos os serviços e processos rclone foram encerrados.${NC}"
}

status() {
    echo -e "${YELLOW}--- Serviços Systemd (User) ---${NC}"
    user_systemctl list-units --all --no-pager 'rclone-*.service'
    
    echo -e "\n${YELLOW}--- Processos Rodando ---${NC}"
    if pgrep -a rclone;
    then
        :
    else
        echo "Nenhum processo rclone."
    fi
}

# Menu Principal
case "$1" in
    start|on|enable)
        start_rclone
        ;;
    stop|off|disable)
        stop_rclone
        ;;
    restart)
        stop_rclone
        sleep 2
        start_rclone
        ;;
    status)
        status
        ;;
    *)
        echo "Uso: $0 {on|off|restart|status}"
        echo "  on:  Habilita e inicia todos os serviços rclone-*.service"
        echo "  off: Para e desabilita todos os serviços"
        exit 1
        ;;
esac