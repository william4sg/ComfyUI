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
LOG_DIR="${PROJECT_DIR}/output/supervisor"

usage() {
    cat <<EOF
用法:
  sudo bash script_examples/deploy_amazon_linux_2023_supervisor.sh [选项]

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
    dnf install -y wget bzip2 tar gzip git python3 python3-pip
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
    "${CONDA_BIN}" run -p "${CONDA_ENV_PATH}" python -m pip install -r "${PROJECT_DIR}/requirements.txt"
    python3 -m pip install --upgrade supervisor
}

prepare_runtime_dirs() {
    echo "==> 准备运行目录"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${LOG_DIR}"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/input"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/output"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/temp"
    install -d -m 0755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${PROJECT_DIR}/user"
    install -d -m 0755 "${SUPERVISOR_CONFIG_DIR}"
}

write_supervisor_main_config() {
    if [[ -f "${SUPERVISOR_MAIN_CONFIG}" ]]; then
        return
    fi

    echo "==> 生成 ${SUPERVISOR_MAIN_CONFIG}"
    cat > "${SUPERVISOR_MAIN_CONFIG}" <<EOF
[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[supervisord]
logfile=/var/log/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[include]
files = ${SUPERVISOR_CONFIG_DIR}/*.conf
EOF
}

write_supervisor_program_config() {
    echo "==> 生成 ${SUPERVISOR_PROGRAM_CONFIG}"
    cat > "${SUPERVISOR_PROGRAM_CONFIG}" <<EOF
[program:${SERVICE_NAME}]
directory=${PROJECT_DIR}
command=${COMFY_PYTHON} ${PROJECT_DIR}/main.py --listen ${LISTEN_HOST} --port ${PORT}
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
ExecStart=/usr/local/bin/supervisord -n -c ${SUPERVISOR_MAIN_CONFIG}
ExecStop=/usr/local/bin/supervisorctl -c ${SUPERVISOR_MAIN_CONFIG} shutdown
ExecReload=/usr/local/bin/supervisorctl -c ${SUPERVISOR_MAIN_CONFIG} reload
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
    /usr/local/bin/supervisorctl -c "${SUPERVISOR_MAIN_CONFIG}" reread
    /usr/local/bin/supervisorctl -c "${SUPERVISOR_MAIN_CONFIG}" update
    /usr/local/bin/supervisorctl -c "${SUPERVISOR_MAIN_CONFIG}" restart "${SERVICE_NAME}" || true
    /usr/local/bin/supervisorctl -c "${SUPERVISOR_MAIN_CONFIG}" status "${SERVICE_NAME}"
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
    prepare_runtime_dirs
    write_supervisor_main_config
    write_supervisor_program_config
    write_systemd_unit
    start_services
    print_summary
}

main "$@"
