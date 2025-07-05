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

# 检查screen会话内部是否有活动进程
check_screen_session_active() {
    if check_screen_session; then
        # 检查screen会话中是否有活动的shell或进程
        local session_info=$(screen -S "$SCREEN_SESSION" -Q windows 2>/dev/null || echo "")
        if [[ -n "$session_info" ]]; then
            return 0  # 有活动进程
        fi
    fi
    return 1  # 无活动进程或会话不存在
}

# 检测特定错误类型
detect_error_type() {
    local error_type=""
    
    # 检查screen会话输出
    if check_screen_session; then
        screen -S "$SCREEN_SESSION" -p 0 -X hardcopy "$WORK_DIR/logs/screen_output.txt" 2>/dev/null || true
        
        if [[ -f "$WORK_DIR/logs/screen_output.txt" ]]; then
            local screen_content=$(cat "$WORK_DIR/logs/screen_output.txt")
            
            # 检测维度不匹配错误
            if echo "$screen_content" | grep -q "expected sequence of length.*at dim"; then
                error_type="dimension_mismatch"
            # 检测P2P连接错误
            elif echo "$screen_content" | grep -q "P2PDaemonError\|Daemon failed to start"; then
                error_type="p2p_connection"
            # 检测内存不足错误
            elif echo "$screen_content" | grep -q "out of memory\|OOM\|MemoryError"; then
                error_type="memory_exhausted"
            # 检测其他常见错误
            elif echo "$screen_content" | grep -q "Error\|Exception\|Traceback"; then
                error_type="generic_error"
            fi
        fi
    fi
    
    echo "$error_type"
}

# 检查训练是否正在运行
check_training_running() {
    # 检查多种可能的训练进程
    local pids=""
    
    # 检查rgym_exp.runner.swarm_launcher进程
    pids=$(pgrep -f "rgym_exp.runner.swarm_launcher" 2>/dev/null || echo "")
    if [[ -n "$pids" ]]; then
        return 0  # 运行中
    fi
    
    # 检查genrl_swarm相关进程
    pids=$(pgrep -f "genrl_swarm.*swarm_launcher" 2>/dev/null || echo "")
    if [[ -n "$pids" ]]; then
        return 0  # 运行中
    fi
    
    # 检查通用的swarm_launcher进程
    pids=$(pgrep -f "swarm_launcher" 2>/dev/null || echo "")
    if [[ -n "$pids" ]]; then
        return 0  # 运行中
    fi
    
    return 1  # 未运行
}

# 增强的健康检查（检查进程是否真的在工作）
check_training_health() {
    if ! check_training_running; then
        return 1  # 进程不存在
    fi
    
    # 检查进程是否消耗CPU（表示在工作）
    local pids=$(pgrep -f "rgym_exp.runner.swarm_launcher\|genrl_swarm.*swarm_launcher\|swarm_launcher" 2>/dev/null || echo "")
    if [[ -n "$pids" ]]; then
        for pid in $pids; do
            local cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
            if [[ -n "$cpu_usage" ]] && (( $(echo "$cpu_usage > 0.1" | bc -l 2>/dev/null || echo "0") )); then
                return 0  # 找到活跃进程
            fi
        done
    fi
    
    # 如果没有活跃进程，检查最近是否有输出
    if check_screen_session; then
        screen -S "$SCREEN_SESSION" -p 0 -X hardcopy "$WORK_DIR/logs/screen_output.txt" 2>/dev/null || true
        
        if [[ -f "$WORK_DIR/logs/screen_output.txt" ]]; then
            local last_modified=$(stat -c %Y "$WORK_DIR/logs/screen_output.txt" 2>/dev/null || echo "0")
            local current_time=$(date +%s)
            local time_diff=$((current_time - last_modified))
            
            # 如果最近5分钟内有输出，认为是健康的
            if [[ $time_diff -lt 300 ]]; then
                return 0
            fi
        fi
    fi
    
    return 1  # 进程可能僵死
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
    
    # 杀死所有可能的训练进程
    pkill -f "rgym_exp.runner.swarm_launcher" 2>/dev/null || true
    pkill -f "genrl_swarm.*swarm_launcher" 2>/dev/null || true
    pkill -f "swarm_launcher" 2>/dev/null || true
    pkill -f "yarn start" 2>/dev/null || true
    pkill -f "node.*modal-login" 2>/dev/null || true
    
    # 清理screen会话
    if check_screen_session; then
        log_info "清理screen会话: $SCREEN_SESSION"
        screen -S "$SCREEN_SESSION" -X quit 2>/dev/null || true
        sleep 2
    fi
    
    # 清理缓存
    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    # 等待一段时间让系统清理
    sleep 10
    
    log_info "内存清理完成"
}

# 确保screen会话不存在（用于重启前清理）
ensure_screen_session_clean() {
    if check_screen_session; then
        log_info "清理现有的screen会话: $SCREEN_SESSION"
        screen -S "$SCREEN_SESSION" -X quit 2>/dev/null || true
        sleep 2
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
    
    # 构建启动命令
    local start_cmd=""
    if [[ -d "$VENV_PATH" ]]; then
        log_info "使用虚拟环境: $VENV_PATH"
        start_cmd="source $VENV_PATH/bin/activate && cd $WORK_DIR && ./$SCRIPT_NAME"
    else
        log_warn "虚拟环境不存在，使用系统Python"
        start_cmd="cd $WORK_DIR && ./$SCRIPT_NAME"
    fi
    
    # 创建新的screen会话并直接执行命令
    log_info "创建新的screen会话并启动训练"
    screen -dmS "$SCREEN_SESSION" bash -c "$start_cmd"
    
    log_info "训练启动命令已在screen会话中执行"
    
    # 等待启动
    sleep 30
    
    # 检查是否成功启动
    local check_count=0
    while [[ $check_count -lt 12 ]]; do  # 检查2分钟
        if check_training_running; then
            log_info "训练成功启动！"
            return 0
        fi
        
        # 检查screen会话是否还存在
        if ! check_screen_session; then
            log_error "Screen会话意外退出，可能启动失败"
            return 1
        fi
        
        sleep 10
        ((check_count++))
    done
    
    log_error "训练启动失败，超时未检测到进程"
    
    # 输出screen会话的最后几行日志用于诊断
    log_info "尝试获取screen会话输出进行诊断..."
    screen -S "$SCREEN_SESSION" -p 0 -X hardcopy "$WORK_DIR/logs/screen_output.txt"
    if [[ -f "$WORK_DIR/logs/screen_output.txt" ]]; then
        log_info "Screen会话输出（最后10行）："
        tail -n 10 "$WORK_DIR/logs/screen_output.txt" | while read line; do
            log_info "  $line"
        done
    fi
    
    return 1
}

# 重启训练
restart_training() {
    local restart_count=0
    
    log_warn "检测到训练停止，准备重启..."
    
    # 清理可能的残留进程
    cleanup_memory
    
    # 多次尝试重启
    while [[ $restart_count -lt $MAX_RESTART_ATTEMPTS ]]; do
        ((restart_count++))
        
        log_info "重启尝试 $restart_count/$MAX_RESTART_ATTEMPTS"
        
        # 确保screen会话干净
        ensure_screen_session_clean
        
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
            
            # 检测错误类型
            local error_type=$(detect_error_type)
            if [[ -n "$error_type" ]]; then
                log_warn "检测到错误类型: $error_type"
                
                case "$error_type" in
                    "dimension_mismatch")
                        log_warn "维度不匹配错误 - 可能需要调整配置"
                        ;;
                    "p2p_connection")
                        log_warn "P2P连接错误 - 将删除身份文件重新生成"
                        ;;
                    "memory_exhausted")
                        log_warn "内存不足错误 - 将进行内存清理"
                        ;;
                    "generic_error")
                        log_warn "通用错误 - 进行标准重启"
                        ;;
                esac
            else
                log_info "未检测到明确错误类型，进行标准重启"
            fi
            
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
        local rgym_pids=$(pgrep -f 'rgym_exp.runner.swarm_launcher' 2>/dev/null || echo "")
        local genrl_pids=$(pgrep -f 'genrl_swarm.*swarm_launcher' 2>/dev/null || echo "")
        local swarm_pids=$(pgrep -f 'swarm_launcher' 2>/dev/null || echo "")
        
        [[ -n "$rgym_pids" ]] && echo "  进程ID (rgym): $rgym_pids"
        [[ -n "$genrl_pids" ]] && echo "  进程ID (genrl): $genrl_pids"
        [[ -n "$swarm_pids" ]] && echo "  进程ID (swarm): $swarm_pids"
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
    pkill -f "rgym_exp.runner.swarm_launcher" 2>/dev/null || true
    pkill -f "genrl_swarm.*swarm_launcher" 2>/dev/null || true
    pkill -f "swarm_launcher" 2>/dev/null || true
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