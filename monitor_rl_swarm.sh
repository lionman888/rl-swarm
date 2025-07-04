#!/bin/bash

# RL Swarm 自动监控和重启脚本
# 用于监控screen会话中的RL Swarm训练，并在停止时自动重启

set -euo pipefail

# 配置参数
SCREEN_SESSION="gensyn"
WORK_DIR="/root/rl-swarm"
VENV_PATH="$WORK_DIR/myenv"
SCRIPT_NAME="run_rl_swarm.sh"
LOG_FILE="/root/rl-swarm/logs/monitor.log"
MAX_RESTART_ATTEMPTS=5
RESTART_DELAY=30  # 重启延迟（秒）
CHECK_INTERVAL=60  # 检查间隔（秒）

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    log_message "INFO" "${GREEN}$1${NC}"
}

log_warn() {
    log_message "WARN" "${YELLOW}$1${NC}"
}

log_error() {
    log_message "ERROR" "${RED}$1${NC}"
}

# 检查screen会话是否存在
check_screen_session() {
    screen -list | grep -q "$SCREEN_SESSION" 2>/dev/null
}

# 检查训练是否正在运行
check_training_running() {
    if check_screen_session; then
        # 检查screen会话中是否有python进程
        local pids=$(pgrep -f "python.*swarm_launcher" 2>/dev/null || echo "")
        if [[ -n "$pids" ]]; then
            return 0  # 运行中
        else
            return 1  # 未运行
        fi
    else
        return 1  # screen会话不存在
    fi
}

# 检查内存使用情况
check_memory_usage() {
    local memory_usage=$(free | grep Mem | awk '{printf("%.0f"), $3/$2 * 100.0}')
    log_info "当前内存使用率: ${memory_usage}%"
    
    if [[ $memory_usage -gt 90 ]]; then
        log_warn "内存使用率过高: ${memory_usage}%"
        return 1
    fi
    return 0
}

# 清理内存和进程
cleanup_memory() {
    log_info "正在清理内存和进程..."
    
    # 杀死可能的僵尸进程
    pkill -f "python.*swarm_launcher" 2>/dev/null || true
    pkill -f "yarn start" 2>/dev/null || true
    pkill -f "node.*modal-login" 2>/dev/null || true
    
    # 清理缓存
    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    # 等待一段时间让系统清理
    sleep 10
    
    log_info "内存清理完成"
}

# 创建或重连screen会话
create_or_attach_screen() {
    if ! check_screen_session; then
        log_info "创建新的screen会话: $SCREEN_SESSION"
        screen -dmS "$SCREEN_SESSION"
        sleep 2
    else
        log_info "重新连接到screen会话: $SCREEN_SESSION"
        # 如果会话存在但没有活动进程，清理会话
        if ! check_training_running; then
            screen -S "$SCREEN_SESSION" -p 0 -X stuff $'\003'  # 发送Ctrl+C
            sleep 2
        fi
    fi
}

# 启动训练
start_training() {
    local attempt=$1
    
    log_info "尝试启动训练 (第 $attempt 次)"
    
    # 确保在正确的工作目录
    cd "$WORK_DIR"
    
    # 创建必要的目录
    mkdir -p logs
    
    # 如果是peer错误导致的重启，删除身份文件
    if [[ $attempt -gt 1 ]]; then
        log_info "删除身份文件，生成新的peer身份"
        rm -f "$WORK_DIR/swarm.pem"
        rm -rf "$WORK_DIR/modal-login/temp-data"/*.json 2>/dev/null || true
    fi
    
    # 检查虚拟环境
    if [[ -d "$VENV_PATH" ]]; then
        log_info "激活虚拟环境: $VENV_PATH"
        ACTIVATE_CMD="source $VENV_PATH/bin/activate"
    else
        log_warn "虚拟环境不存在，使用系统Python"
        ACTIVATE_CMD=""
    fi
    
    # 在screen会话中启动训练
    if [[ -n "$ACTIVATE_CMD" ]]; then
        screen -S "$SCREEN_SESSION" -p 0 -X stuff "$ACTIVATE_CMD && cd $WORK_DIR && ./$SCRIPT_NAME"$'\n'
    else
        screen -S "$SCREEN_SESSION" -p 0 -X stuff "cd $WORK_DIR && ./$SCRIPT_NAME"$'\n'
    fi
    
    log_info "训练启动命令已发送到screen会话"
    
    # 等待启动
    sleep 30
    
    # 检查是否成功启动
    local check_count=0
    while [[ $check_count -lt 12 ]]; do  # 检查2分钟
        if check_training_running; then
            log_info "训练成功启动！"
            return 0
        fi
        sleep 10
        ((check_count++))
    done
    
    log_error "训练启动失败，超时未检测到进程"
    return 1
}

# 重启训练
restart_training() {
    local restart_count=0
    
    log_warn "检测到训练停止，准备重启..."
    
    # 清理可能的残留进程
    cleanup_memory
    
    # 创建或重连screen会话
    create_or_attach_screen
    
    # 多次尝试重启
    while [[ $restart_count -lt $MAX_RESTART_ATTEMPTS ]]; do
        ((restart_count++))
        
        log_info "重启尝试 $restart_count/$MAX_RESTART_ATTEMPTS"
        
        if start_training $restart_count; then
            log_info "训练重启成功！"
            return 0
        else
            log_error "第 $restart_count 次重启失败"
            
            if [[ $restart_count -lt $MAX_RESTART_ATTEMPTS ]]; then
                log_info "等待 $RESTART_DELAY 秒后重试..."
                sleep $RESTART_DELAY
            fi
        fi
    done
    
    log_error "达到最大重启次数，停止监控"
    return 1
}

# 主监控循环
monitor_loop() {
    log_info "开始监控RL Swarm训练"
    log_info "Screen会话: $SCREEN_SESSION"
    log_info "工作目录: $WORK_DIR"
    log_info "检查间隔: $CHECK_INTERVAL 秒"
    
    while true; do
        if check_training_running; then
            log_info "训练正在运行中..."
            
            # 检查内存使用情况
            if ! check_memory_usage; then
                log_warn "内存使用率过高，可能需要重启"
                # 可以选择是否立即重启
                # restart_training
            fi
            
        else
            log_warn "训练已停止！"
            
            # 尝试重启
            if ! restart_training; then
                log_error "重启失败，退出监控"
                break
            fi
        fi
        
        # 等待下次检查
        sleep $CHECK_INTERVAL
    done
}

# 信号处理
cleanup_on_exit() {
    log_info "监控脚本退出"
    exit 0
}

trap cleanup_on_exit SIGINT SIGTERM

# 检查状态
check_status() {
    echo "=== RL Swarm 状态检查 ==="
    echo ""
    
    echo "Screen会话状态:"
    if check_screen_session; then
        echo "  ✓ Screen会话 '$SCREEN_SESSION' 存在"
    else
        echo "  ✗ Screen会话 '$SCREEN_SESSION' 不存在"
    fi
    
    echo ""
    echo "训练进程状态:"
    if check_training_running; then
        echo "  ✓ 训练正在运行"
        echo "  进程ID: $(pgrep -f 'python.*swarm_launcher' 2>/dev/null || echo '无')"
    else
        echo "  ✗ 训练未运行"
    fi
    
    echo ""
    echo "内存使用情况:"
    free -h
    
    echo ""
    echo "磁盘使用情况:"
    df -h /
    
    echo ""
    echo "相关进程:"
    ps aux | grep -E "(python.*swarm|yarn|node)" | grep -v grep || echo "  无相关进程"
}

# 显示帮助信息
show_help() {
    echo "RL Swarm 自动监控脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示帮助信息"
    echo "  -s, --status   检查当前状态"
    echo "  -r, --restart  手动重启训练"
    echo "  -k, --kill     停止所有相关进程"
    echo ""
    echo "监控配置:"
    echo "  Screen会话: $SCREEN_SESSION"
    echo "  工作目录: $WORK_DIR"
    echo "  检查间隔: $CHECK_INTERVAL 秒"
    echo "  最大重启次数: $MAX_RESTART_ATTEMPTS"
}

# 停止所有相关进程
kill_all_processes() {
    log_info "停止所有相关进程..."
    
    # 停止训练进程
    pkill -f "python.*swarm_launcher" 2>/dev/null || true
    pkill -f "yarn start" 2>/dev/null || true
    pkill -f "node.*modal-login" 2>/dev/null || true
    
    # 结束screen会话
    if check_screen_session; then
        screen -S "$SCREEN_SESSION" -X quit 2>/dev/null || true
    fi
    
    log_info "所有进程已停止"
}

# 主程序
main() {
    # 检查运行环境
    if ! command -v screen &> /dev/null; then
        log_error "screen命令未找到，请安装screen"
        exit 1
    fi
    
    # 检查工作目录
    if [[ ! -d "$WORK_DIR" ]]; then
        log_error "工作目录不存在: $WORK_DIR"
        exit 1
    fi
    
    # 检查脚本文件
    if [[ ! -f "$WORK_DIR/$SCRIPT_NAME" ]]; then
        log_error "脚本文件不存在: $WORK_DIR/$SCRIPT_NAME"
        exit 1
    fi
    
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # 开始监控
    monitor_loop
}

# 参数解析
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -s|--status)
        check_status
        exit 0
        ;;
    -r|--restart)
        log_info "手动重启训练"
        restart_training
        exit 0
        ;;
    -k|--kill)
        kill_all_processes
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "未知参数: $1"
        show_help
        exit 1
        ;;
esac