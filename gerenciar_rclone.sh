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

resolve_services() {
    local scope="$1"
    local services=""
    shift

    if [ "$scope" = "files" ]; then
        services=$(user_systemctl list-unit-files --no-legend 'rclone-*.service' | awk '{print $1}')
    else
        services=$(user_systemctl list-units --all --no-legend --plain 'rclone-*.service' | awk '{print $1}')
    fi

    if [ "$#" -eq 0 ]; then
        echo "$services"
        return
    fi

    local filtered=""
    local filter=""
    for filter in "$@"; do
        local normalized="$filter"
        local exact=""
        local matches=""
        if [[ "$normalized" != rclone-* ]]; then
            normalized="rclone-$normalized"
        fi
        if [[ "$normalized" != *.service ]]; then
            normalized="${normalized}.service"
        fi

        exact=$(echo "$services" | awk -v s="$normalized" '$0 == s')
        if [ -n "$exact" ]; then
            filtered="${filtered}${exact}"$'\n'
        else
            matches=$(echo "$services" | grep -F "$filter" || true)
            if [ -n "$matches" ]; then
                filtered="${filtered}${matches}"$'\n'
            fi
        fi
    done

    echo "$filtered" | awk 'NF' | sort -u
}

fallback_list_services_from_dir() {
    local base_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local found=0
    for unit in "$base_dir"/rclone-*.service; do
        [ -e "$unit" ] || continue
        short="${unit##*/}"
        short="${short#rclone-}"
        short="${short%.service}"
        printf "%-40s %s\n" "$short" "$unit"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "Nenhum unit file rclone encontrado em $base_dir."
    fi
}

list_services() {
    echo -e "${YELLOW}--- Serviços disponíveis (unit files) ---${NC}"
    local output
    if output=$(user_systemctl list-unit-files --no-pager 'rclone-*.service' 2>&1); then
        echo "$output" | tail -n +2 | while read -r unit state preset; do
            if [[ -z "$unit" ]]; then
                continue
            fi
            short="${unit#rclone-}"
            short="${short%.service}"
            printf "%-40s %-10s %s\n" "$short" "$state" "$unit"
        done
    else
        echo -e "${RED}Não foi possível acessar o barramento systemd --user:${NC}"
        echo "$output"
        echo "Mostrando os unit files existentes no diretório de serviços do usuário:"
        fallback_list_services_from_dir
    fi
    echo
    echo "Use 'on finance', 'off mega', etc., passando o trecho após 'rclone-'."
}

start_rclone() {
    local filters=("$@")
    echo -e "${GREEN}Habilitando e iniciando serviços systemd do rclone...${NC}"
    
    # Obtém a lista dinâmica de serviços
    SERVICES=$(resolve_services "files" "${filters[@]}")
    
    if [ -z "$SERVICES" ]; then
        echo -e "${YELLOW}Nenhum serviço rclone encontrado.${NC}"
        return 1
    fi
    
    for SERVICE in $SERVICES;
    do
        echo "Iniciando $SERVICE..."
        user_systemctl enable "$SERVICE" --now
    done
    
    echo -e "${GREEN}Concluído. Verificando status...${NC}"
    sleep 2
    status "${filters[@]}"
}

stop_rclone() {
    local filters=("$@")
    echo -e "${RED}Parando e desabilitando serviços systemd do rclone...${NC}"
    
    # Lista serviços ativos ou carregados
    SERVICES=$(resolve_services "units" "${filters[@]}")
    
    if [ -n "$SERVICES" ]; then
        for SERVICE in $SERVICES;
        do
            echo "Parando $SERVICE..."
            user_systemctl stop "$SERVICE"
            user_systemctl disable "$SERVICE" 2>/dev/null
        done
    else
        echo "Nenhum serviço rclone encontrado."
    fi

    if [ "${#filters[@]}" -eq 0 ]; then
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
    else
        echo -e "${GREEN}Serviços selecionados encerrados.${NC}"
    fi
}

status() {
    local filters=("$@")
    echo -e "${YELLOW}--- Serviços Systemd (User) ---${NC}"
    if [ "${#filters[@]}" -eq 0 ]; then
        user_systemctl list-units --all --no-pager 'rclone-*.service'
    else
        local services=""
        services=$(resolve_services "files" "${filters[@]}")
        if [ -n "$services" ]; then
            for SERVICE in $services;
            do
                local active_label="Inativo"
                local enabled_label=""
                if user_systemctl is-active --quiet "$SERVICE"; then
                    active_label="Ativo"
                fi
                enabled_label=$(user_systemctl is-enabled "$SERVICE" 2>/dev/null || true)
                if [ -z "$enabled_label" ]; then
                    enabled_label="Desconhecido"
                else
                    enabled_label="$(echo "$enabled_label" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
                fi
                printf "%-40s %s / %s\n" "$SERVICE" "$active_label" "$enabled_label"
            done
        else
            echo "Nenhum serviço rclone encontrado."
        fi
    fi
    
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
        shift
        start_rclone "$@"
        ;;
    activate)
        shift
        start_rclone "$@"
        ;;
    stop|off|disable)
        shift
        stop_rclone "$@"
        ;;
    deactivate)
        shift
        stop_rclone "$@"
        ;;
    restart)
        shift
        stop_rclone "$@"
        sleep 2
        start_rclone "$@"
        ;;
    status)
        shift
        status "$@"
        ;;
    list|ls)
        list_services
        ;;
    *)
        echo "Uso: $0 {on|off|restart|status|list|activate|deactivate} [servico...]"
        echo "  on/activate: Habilita e inicia todos os serviços ou os informados"
        echo "  off/deactivate: Para e desabilita todos os serviços ou os informados"
        echo "  restart: Para e inicia novamente os serviços informados"
        echo "  status: Mostra status de todos ou serviços específicos"
        echo "  list: Lista os unit files com o nome usado após 'rclone-'"
        exit 1
        ;;
esac
