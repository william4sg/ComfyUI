#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SERVICE_NAME="comfyui"
SERVICE_USER="ec2-user"
LISTEN_HOST="0.0.0.0"
PORT="8188"
CONDA_ENV_NAME="ComfyUI"
MINICONDA_DIR="/opt/miniconda3"
SUPERVISOR_CONFIG_DIR="/etc/supervisord.d"
SUPERVISOR_MAIN_CONFIG="/etc/supervisord.conf"
SYSTEMD_UNIT_PATH="/etc/systemd/system/supervisord.service"
SUPERVISOR_SOCKET="/var/run/supervisor.sock"
LOG_DIR="${PROJECT_DIR}/output/supervisor"
SUPERVISORD_BIN=""
SUPERVISORCTL_BIN=""

usage() {
    cat <<EOF
用法:
  sudo bash deploy/deploy_amazon_linux_2023_supervisor.sh [选项]

选项:
  --project-dir PATH        ComfyUI 项目目录，默认当前仓库根目录
  --service-user USER       运行服务的系统用户，默认 ec2-user
  --listen HOST             监听地址，默认 0.0.0.0
  --port PORT               监听端口，默认 8188
  --conda-env-name NAME     conda 环境名，默认 ComfyUI
  --miniconda-dir PATH      Miniconda 安装目录，默认 /opt/miniconda3
  --service-name NAME       supervisor 程序名，默认 comfyui
  -h, --help                显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --service-user)
            SERVICE_USER="$2"
            shift 2
            ;;
        --listen)
            LISTEN_HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --conda-env-name)
            CONDA_ENV_NAME="$2"
            shift 2
            ;;
        --miniconda-dir)
            MINICONDA_DIR="$2"
            shift 2
            ;;
        --service-name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage
            exit 1
            ;;
    esac
done

PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"
LOG_DIR="${PROJECT_DIR}/output/supervisor"
CONDA_BIN="${MINICONDA_DIR}/bin/conda"
CONDA_ENV_PATH="${MINICONDA_DIR}/envs/${CONDA_ENV_NAME}"
COMFY_PYTHON="${CONDA_ENV_PATH}/bin/python"
SUPERVISOR_PROGRAM_CONFIG="${SUPERVISOR_CONFIG_DIR}/${SERVICE_NAME}.conf"

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "请使用 root 或 sudo 运行此脚本。" >&2
        exit 1
    fi
}

check_inputs() {
    if [[ ! -f "${PROJECT_DIR}/main.py" ]]; then
        echo "未找到 ${PROJECT_DIR}/main.py，请通过 --project-dir 指定正确的 ComfyUI 项目目录。" >&2
        exit 1
    fi

    if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
        echo "系统用户 ${SERVICE_USER} 不存在，请先创建该用户或通过 --service-user 指定已有用户。" >&2
        exit 1
    fi
}

install_system_packages() {
    echo "==> 安装系统依赖"
    dnf install -y wget bzip2 tar gzip git iproute python3 python3-pip
}

install_miniconda() {
    if [[ -x "${CONDA_BIN}" ]]; then
        echo "==> 已检测到 Miniconda: ${MINICONDA_DIR}"
        return
    fi

    echo "==> 安装 Miniconda 到 ${MINICONDA_DIR}"
    local installer="/tmp/miniconda.sh"
    wget -O "${installer}" "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    bash "${installer}" -b -p "${MINICONDA_DIR}"
    rm -f "${installer}"
}

ensure_conda_env() {
    if [[ -x "${COMFY_PYTHON}" ]]; then
        echo "==> 已检测到 conda 环境: ${CONDA_ENV_NAME}"
        return
    fi

    echo "==> 创建 conda 环境: ${CONDA_ENV_NAME}"
    "${CONDA_BIN}" create -y -n "${CONDA_ENV_NAME}" python=3.10
}

install_python_dependencies() {
    echo "==> 安装 Python 依赖"
    "${CONDA_BIN}" run -p "${CONDA_ENV_PATH}" python -m pip install --upgrade pip
    # 每次部署都强制重装依赖，避免环境里残留旧版本或本地改动导致实际运行依赖漂移。
    "${CONDA_BIN}" run -p "${CONDA_ENV_PATH}" python -m pip install --upgrade --force-reinstall -r "${PROJECT_DIR}/requirements.txt"
    # 部署脚本默认启用 manager，因此这里也按相同策略强制重装它的依赖，保持环境一致。
    "${CONDA_BIN}" run -p "${CONDA_ENV_PATH}" python -m pip install --upgrade --force-reinstall -r "${PROJECT_DIR}/manager_requirements.txt"
    python3 -m pip install --upgrade supervisor
}

ensure_supervisor_binaries() {
    SUPERVISORD_BIN="$(command -v supervisord || true)"
    SUPERVISORCTL_BIN="$(command -v supervisorctl || true)"

    if [[ -z "${SUPERVISORD_BIN}" || -z "${SUPERVISORCTL_BIN}" ]]; then
        echo "未找到 supervisord 或 supervisorctl，可执行文件安装位置与当前环境不一致。" >&2
        echo "请检查 python3 -m pip install --upgrade supervisor 是否成功执行。" >&2
        exit 1
    fi
}

prepare_runtime_dirs() {
    echo "==> 准备运行目录"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${LOG_DIR}"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/input"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/output"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/temp"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/user"
    install -d -m 0755 "${SUPERVISOR_CONFIG_DIR}"
    # supervisord 要求 childlogdir 预先存在，否则主进程启动失败，后续
    # supervisorctl 会因为找不到 unix socket 报 FileNotFoundError。
    install -d -m 0755 /var/log/supervisor
}

write_supervisor_main_config() {
    if [[ -f "${SUPERVISOR_MAIN_CONFIG}" ]]; then
        return
    fi

    echo "==> 生成 ${SUPERVISOR_MAIN_CONFIG}"
    cat > "${SUPERVISOR_MAIN_CONFIG}" <<EOF
[unix_http_server]
file=${SUPERVISOR_SOCKET}
chmod=0700

[supervisord]
logfile=/var/log/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://${SUPERVISOR_SOCKET}

[include]
files = ${SUPERVISOR_CONFIG_DIR}/*.conf
EOF
}

validate_supervisor_main_config() {
    if [[ ! -f "${SUPERVISOR_MAIN_CONFIG}" ]]; then
        return
    fi

    if ! grep -Fqx "file=${SUPERVISOR_SOCKET}" "${SUPERVISOR_MAIN_CONFIG}"; then
        echo "${SUPERVISOR_MAIN_CONFIG} 缺少 unix_http_server socket 配置，当前脚本无法安全复用该配置。" >&2
        exit 1
    fi

    if ! grep -Fqx "serverurl=unix://${SUPERVISOR_SOCKET}" "${SUPERVISOR_MAIN_CONFIG}"; then
        echo "${SUPERVISOR_MAIN_CONFIG} 缺少 supervisorctl socket 配置，当前脚本无法安全复用该配置。" >&2
        exit 1
    fi

    if ! grep -Fqx "files = ${SUPERVISOR_CONFIG_DIR}/*.conf" "${SUPERVISOR_MAIN_CONFIG}"; then
        echo "${SUPERVISOR_MAIN_CONFIG} 没有包含 ${SUPERVISOR_CONFIG_DIR}/*.conf，当前脚本生成的服务配置不会生效。" >&2
        exit 1
    fi
}

write_supervisor_program_config() {
    echo "==> 生成 ${SUPERVISOR_PROGRAM_CONFIG}"
    cat > "${SUPERVISOR_PROGRAM_CONFIG}" <<EOF
[program:${SERVICE_NAME}]
directory=${PROJECT_DIR}
command=${COMFY_PYTHON} ${PROJECT_DIR}/main.py --listen ${LISTEN_HOST} --port ${PORT} --enable-manager
user=${SERVICE_USER}

autostart=true
autorestart=true
startsecs=5
startretries=3
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=120

environment=PYTHONUNBUFFERED="1"

stdout_logfile=${LOG_DIR}/comfyui.stdout.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10

stderr_logfile=${LOG_DIR}/comfyui.stderr.log
stderr_logfile_maxbytes=50MB
stderr_logfile_backups=10
EOF
}

write_systemd_unit() {
    echo "==> 生成 ${SYSTEMD_UNIT_PATH}"
    cat > "${SYSTEMD_UNIT_PATH}" <<EOF
[Unit]
Description=Supervisor process control system
After=network.target

[Service]
Type=simple
ExecStart=${SUPERVISORD_BIN} -n -c ${SUPERVISOR_MAIN_CONFIG}
ExecStop=${SUPERVISORCTL_BIN} -c ${SUPERVISOR_MAIN_CONFIG} shutdown
ExecReload=${SUPERVISORCTL_BIN} -c ${SUPERVISOR_MAIN_CONFIG} reload
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

start_services() {
    echo "==> 启动 supervisord 并加载 ${SERVICE_NAME}"
    systemctl daemon-reload
    systemctl enable --now supervisord
    if ! systemctl is-active --quiet supervisord; then
        echo "supervisord 启动失败，请检查以下信息：" >&2
        systemctl status supervisord --no-pager || true
        journalctl -u supervisord -n 50 --no-pager || true
        exit 1
    fi
    "${SUPERVISORCTL_BIN}" -c "${SUPERVISOR_MAIN_CONFIG}" reread
    # 先停掉旧的 supervisor 进程实例，避免同名服务在配置更新期间残留旧进程。
    "${SUPERVISORCTL_BIN}" -c "${SUPERVISOR_MAIN_CONFIG}" stop "${SERVICE_NAME}" || true
    "${SUPERVISORCTL_BIN}" -c "${SUPERVISOR_MAIN_CONFIG}" update
    # 如果端口上还有手工启动或异常残留的旧进程，这里兜底清掉，避免新实例启动时报地址已被占用。
    local port_pids
    port_pids="$(ss -ltnp "( sport = :${PORT} )" 2>/dev/null | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u || true)"
    if [[ -n "${port_pids}" ]]; then
        echo "==> 检查占用端口 ${PORT} 的旧进程"
        while IFS= read -r pid; do
            [[ -n "${pid}" ]] || continue
            local process_info
            local process_user
            local process_command
            process_info="$(ps -o user= -o command= -p "${pid}" 2>/dev/null || true)"
            process_user="${process_info%% *}"
            process_command="${process_info#* }"

            if [[ "${process_user}" == "${SERVICE_USER}" && "${process_command}" == *"${PROJECT_DIR}/main.py"* ]]; then
                echo "==> 清理 ComfyUI 旧进程: pid=${pid}"
                kill "${pid}" || true
                continue
            fi

            echo "端口 ${PORT} 被非 ComfyUI 进程占用，已停止部署以避免误杀。" >&2
            echo "占用进程: pid=${pid} user=${process_user} command=${process_command}" >&2
            exit 1
        done <<< "${port_pids}"
    fi
    "${SUPERVISORCTL_BIN}" -c "${SUPERVISOR_MAIN_CONFIG}" start "${SERVICE_NAME}"

    local service_status
    service_status="$("${SUPERVISORCTL_BIN}" -c "${SUPERVISOR_MAIN_CONFIG}" status "${SERVICE_NAME}")"
    echo "${service_status}"
    if [[ "${service_status}" != *" RUNNING "* && "${service_status}" != *" RUNNING" ]]; then
        echo "ComfyUI 服务未进入 RUNNING 状态，请检查日志。" >&2
        exit 1
    fi
}

print_summary() {
    cat <<EOF

部署完成。

服务名称: ${SERVICE_NAME}
项目目录: ${PROJECT_DIR}
监听地址: http://${LISTEN_HOST}:${PORT}
conda 环境: ${CONDA_ENV_NAME}

常用命令:
  systemctl status supervisord
  supervisorctl -c ${SUPERVISOR_MAIN_CONFIG} status
  supervisorctl -c ${SUPERVISOR_MAIN_CONFIG} restart ${SERVICE_NAME}
  tail -f ${LOG_DIR}/comfyui.stdout.log
  tail -f ${LOG_DIR}/comfyui.stderr.log
EOF
}

main() {
    require_root
    check_inputs
    install_system_packages
    install_miniconda
    ensure_conda_env
    install_python_dependencies
    ensure_supervisor_binaries
    prepare_runtime_dirs
    validate_supervisor_main_config
    write_supervisor_main_config
    write_supervisor_program_config
    write_systemd_unit
    start_services
    print_summary
}

main "$@"
