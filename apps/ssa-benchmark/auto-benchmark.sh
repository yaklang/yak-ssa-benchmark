#!/bin/bash
# =============================================================================
# SSA Benchmark Auto Runner
# 功能: 自动检测最新 Yaklang 引擎版本并执行基准测试
# 执行周期: 每 5 分钟检查一次
# 特性: 支持多项目配置，自动生成和对比基线
# =============================================================================

# 不使用 set -e，手动处理错误以便记录详细信息

# ============= 配置部分 =============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR=/root/yak-ssa-benchmark/ssa-benchmark-service
ENGINE_DIR="${SERVICE_DIR}/yak-engine"
LOG_FILE="${SERVICE_DIR}/auto-benchmark.log"
LOCK_FILE="${SERVICE_DIR}/benchmark.lock"
CONFIG_FILE="${SERVICE_DIR}/config.json"
FAILURE_LOG_DIR="${SERVICE_DIR}/failure-logs"

# 工作目录
WORK_DIR=/root/yak-ssa-benchmark
APP_PATH="apps/ssa-benchmark"

# 配置文件路径
BENCHMARK_FRONTEND="${WORK_DIR}/${APP_PATH}/report-viewer.html"
CONFIGS_DIR="${WORK_DIR}/${APP_PATH}/configs"
REPORT_DIR=/root/ssa-benchmark-reports

# 基线版本 - 用于生成初始基线文件
BASELINE_YAK_VERSION="1.4.5-beta2"

# 引擎版本信息
VERSION_URL="https://yaklang.oss-accelerate.aliyuncs.com/yak/latest/version.txt"
ENGINE_DOWNLOAD_URL_TEMPLATE="https://yaklang.oss-accelerate.aliyuncs.com/yak/{VERSION}/yak_linux_amd64"

# ============= 工具函数 =============
# 清理项目名称中的特殊字符，生成安全的目录名
sanitize_project_name() {
    local name="$1"
    # 替换不安全的字符为下划线，保留字母、数字、下划线、连字符
    echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//'
}

# ============= 日志函数 =============
# 只写入文件日志（静默模式，不输出到 journalctl）
log_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" >> "$LOG_FILE"
}

# 输出到 journalctl 和文件（重要信息）
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE" >&2
}

# 错误信息，输出到 journalctl 和文件
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&2
}

# 警告信息，输出到 journalctl 和文件
log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" | tee -a "$LOG_FILE" >&2
}

# ============= 初始化 =============
init_service() {
    # 创建必要的目录（静默）
    mkdir -p "$SERVICE_DIR"
    mkdir -p "$ENGINE_DIR"
    mkdir -p "$REPORT_DIR"
    mkdir -p "$FAILURE_LOG_DIR"
    
    # 如果配置文件不存在，创建初始配置
    if [ ! -f "$CONFIG_FILE" ]; then
        log_file "Creating initial config file..."
        cat > "$CONFIG_FILE" <<EOF
# SSA Benchmark Auto Runner Configuration
# Last updated: $(date '+%Y-%m-%d %H:%M:%S')

current_version=
last_run_time=
last_check_time=
engine_path=
total_runs=0
last_run_success=false
last_run_error=
EOF
    fi
    
    log_file "Service directories initialized"
}

# ============= 配置文件操作 =============
read_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ""
        return
    fi

    local key="$1"
    # 读取 Key=Value 格式的配置
    local value=$(grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- || echo "")
    echo "$value"
}

update_config() {
    local key="$1"
    local value="$2"

    if [ ! -f "$CONFIG_FILE" ]; then
        init_service
    fi

    # 更新 Key=Value 格式的配置
    # 使用 grep + 重写文件的方式，避免 sed 处理特殊字符的问题
    local tmp_file="${CONFIG_FILE}.tmp"

    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        # 更新现有键：先写入其他行，再写入新值
        grep -v "^${key}=" "$CONFIG_FILE" > "$tmp_file"
        echo "${key}=${value}" >> "$tmp_file"
        mv "$tmp_file" "$CONFIG_FILE"
    else
        # 添加新键（追加到文件末尾）
        echo "${key}=${value}" >> "$CONFIG_FILE"
    fi
}

# 数字和布尔值也使用相同的函数
update_config_number() {
    update_config "$1" "$2"
}

update_config_bool() {
    update_config "$1" "$2"
}

# ============= 版本检查 =============
get_latest_version() {
    log_file "Fetching latest engine version from $VERSION_URL..."
    
    local version
    local curl_exit
    
    version=$(curl -s --connect-timeout 10 --max-time 30 "$VERSION_URL" 2>/dev/null)
    curl_exit=$?
    
    if [ $curl_exit -ne 0 ]; then
        log_error "Failed to fetch latest version: network error (curl exit code: $curl_exit)"
        return 1
    fi
    
    # 清理空白字符
    version=$(echo "$version" | tr -d '[:space:]')
    
    if [ -z "$version" ]; then
        log_error "Failed to fetch latest version: empty response from server"
        return 1
    fi
    
    log_file "Latest version: $version"
    echo "$version"
}

# ============= 引擎下载 =============
download_engine() {
    local version="$1"
    # 直接构造 URL，避免使用模板替换
    local engine_url="https://yaklang.oss-accelerate.aliyuncs.com/yak/${version}/yak_linux_amd64"
    local engine_path="${ENGINE_DIR}/yak-${version}"
    
    log_file "Downloading engine version $version..."
    log_file "URL: $engine_url"
    log_file "Target: $engine_path"
    
    # 如果文件已存在且可执行，跳过下载
    if [ -f "$engine_path" ] && [ -x "$engine_path" ]; then
        log_file "Engine already exists and is executable: $engine_path"
        echo "$engine_path"
        return 0
    fi
    
    # 下载引擎
    local tmp_file="${engine_path}.tmp"
    if ! curl -L --progress-bar --connect-timeout 30 --max-time 300 \
         -o "$tmp_file" "$engine_url" 2>/dev/null; then
        log_error "Failed to download engine $version: network error"
        rm -f "$tmp_file"
        return 1
    fi
    
    # 验证下载的文件
    if [ ! -f "$tmp_file" ] || [ ! -s "$tmp_file" ]; then
        log_error "Failed to download engine $version: file is empty or missing"
        rm -f "$tmp_file"
        return 1
    fi
    
    # 移动到目标位置
    mv "$tmp_file" "$engine_path"
    
    # 添加执行权限
    chmod +x "$engine_path"
    
    # 验证文件类型
    if ! file "$engine_path" | grep -q "executable"; then
        log_error "Failed to download engine $version: not a valid executable"
        rm -f "$engine_path"
        return 1
    fi
    
    log_file "Engine downloaded successfully: $engine_path"
    echo "$engine_path"
}

# ============= 保存失败日志 =============
# 用于扫描失败
save_scan_failure_log() {
    local project_name="$1"
    local version="$2"
    local scan_log="$3"
    local scan_result="$4"
    
    local timestamp=$(date '+%Y%m%d-%H%M%S')
    local safe_project_name=$(sanitize_project_name "$project_name")
    local failure_log_file="${FAILURE_LOG_DIR}/${safe_project_name}-scan-${timestamp}.log"
    
    # 创建失败日志
    {
        echo "=========================================="
        echo "Scan Failure Report"
        echo "=========================================="
        echo "Project: $project_name"
        echo "Engine Version: $version"
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Failure Type: Scan Failed"
        echo "=========================================="
        echo ""
        echo "=== Scan Output ==="
        if [ -f "$scan_log" ]; then
            cat "$scan_log"
        else
            echo "(No scan log available)"
        fi
        echo ""
        echo "=========================================="
    } > "$failure_log_file"
    
    log_info "Failure log saved: $failure_log_file"
    
    # 删除空的或失败的 scan 结果文件
    if [ -n "$scan_result" ] && [ -f "$scan_result" ]; then
        rm -f "$scan_result"
        log_file "Removed failed scan result file: $scan_result"
    fi
}

# 用于对比失败
save_comparison_failure_log() {
    local project_name="$1"
    local version="$2"
    local compare_log="$3"
    local baseline_file="$4"
    local scan_result="$5"
    local comparison_report="$6"
    
    local timestamp=$(date '+%Y%m%d-%H%M%S')
    local safe_project_name=$(sanitize_project_name "$project_name")
    local failure_log_file="${FAILURE_LOG_DIR}/${safe_project_name}-compare-${timestamp}.log"
    
    # 创建失败日志
    {
        echo "=========================================="
        echo "Comparison Failure Report"
        echo "=========================================="
        echo "Project: $project_name"
        echo "Engine Version: $version"
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Failure Type: Baseline Comparison Failed"
        echo "Baseline File: $baseline_file"
        echo "Scan Result: $scan_result"
        echo "Comparison Report: $comparison_report"
        echo "=========================================="
        echo ""
        echo "=== Comparison Output ==="
        if [ -f "$compare_log" ]; then
            cat "$compare_log"
        else
            echo "(No comparison log available)"
        fi
        echo ""
        echo "=== Comparison Report Content ==="
        if [ -f "$comparison_report" ]; then
            cat "$comparison_report"
        else
            echo "(No comparison report available)"
        fi
        echo ""
        echo "=========================================="
    } > "$failure_log_file"
    
    log_info "Failure log saved: $failure_log_file"
}

# ============= 扫描单个项目 =============
scan_project() {
    local engine_path="$1"
    local version="$2"
    local project_dir="$3"
    local config_file="$4"
    
    local project_name=$(basename "$project_dir")
    local safe_project_name=$(sanitize_project_name "$project_name")
    log_file "Scanning project: $project_name (safe name: $safe_project_name)"
    log_file "Config: $config_file"
    
    # 创建项目专属的扫描结果目录（使用新结构：project_name/scan）
    local project_scan_dir="${REPORT_DIR}/${safe_project_name}/scan"
    mkdir -p "$project_scan_dir"
    
    # 生成带时间戳的扫描结果文件名
    local timestamp=$(date '+%Y%m%d-%H%M%S')
    local scan_result="${project_scan_dir}/scan-${timestamp}.json"
    
    # 创建临时日志文件
    local scan_log="${SERVICE_DIR}/scan-${safe_project_name}-${timestamp}.tmp.log"
    
    # 执行扫描
    log_file "Executing scan for $project_name with engine $version..."
    cd "$WORK_DIR" || return 1
    
    # 使用CLI参数指定输出路径
    "$engine_path" code-scan -c "$config_file" \
        --output "$scan_result" \
        > "$scan_log" 2>&1
    
    local scan_exit=$?
    
    # 将扫描日志追加到主日志文件
    cat "$scan_log" >> "$LOG_FILE"
    
    if [ $scan_exit -ne 0 ]; then
        log_error "Scan failed for $project_name (exit code: $scan_exit)"
        # 保存失败日志并清理空的 scan 文件
        save_scan_failure_log "$project_name" "$version" "$scan_log" "$scan_result"
        rm -f "$scan_log"
        return 1
    fi
    
    rm -f "$scan_log"
    
    log_file "Scan completed for $project_name, result: $scan_result"
    
    # 检查扫描结果文件是否存在且非空
    if [ ! -f "$scan_result" ]; then
        log_error "Scan result file not found: $scan_result"
        return 1
    fi
    
    if [ ! -s "$scan_result" ]; then
        log_error "Scan result file is empty: $scan_result"
        rm -f "$scan_result"
        return 1
    fi
    
    echo "$scan_result"
}

# ============= 确保基线文件存在 =============
ensure_baseline() {
    local project_dir="$1"
    local config_file="$2"
    local project_name=$(basename "$project_dir")
    local baseline_file="${project_dir}/baseline.json"
    
    # 如果基线文件已存在，直接返回
    if [ -f "$baseline_file" ]; then
        log_file "Baseline file exists for $project_name: $baseline_file"
        return 0
    fi
    
    log_file "No baseline found for $project_name, generating with version $BASELINE_YAK_VERSION..."
    
    # 下载基线版本引擎
    local baseline_engine=$(download_engine "$BASELINE_YAK_VERSION")
    if [ $? -ne 0 ] || [ -z "$baseline_engine" ]; then
        log_error "Failed to download baseline engine version $BASELINE_YAK_VERSION"
        return 1
    fi
    
    # 使用基线版本执行扫描
    local baseline_scan_result=$(scan_project "$baseline_engine" "$BASELINE_YAK_VERSION" "$project_dir" "$config_file")
    if [ $? -ne 0 ] || [ -z "$baseline_scan_result" ]; then
        log_error "Failed to generate baseline scan for $project_name"
        return 1
    fi
    
    # 复制扫描结果作为基线
    if [ ! -f "$baseline_scan_result" ]; then
        log_error "Baseline scan result not found: $baseline_scan_result"
        return 1
    fi
    
    cp "$baseline_scan_result" "$baseline_file"
    log_file "Baseline file generated for $project_name: $baseline_file"
    
    # 删除用于生成基线的 scan 文件，因为它只是基线的来源，不应该保留在 scan 目录中
    rm -f "$baseline_scan_result"
    log_file "Removed baseline scan file: $baseline_scan_result"
    
    return 0
}

# ============= 执行基准测试 =============
run_benchmark() {
    local engine_path="$1"
    local version="$2"
    
    log_file "=========================================="
    log_file "Starting benchmark test with engine $version"
    log_file "Engine: $engine_path"
    log_file "Configs Dir: $CONFIGS_DIR"
    log_file "Report Dir: $REPORT_DIR"
    log_file "=========================================="
    
    # 检查配置目录
    if [ ! -d "$CONFIGS_DIR" ]; then
        log_error "Configs directory not found: $CONFIGS_DIR"
        return 1
    fi
    
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    log_file "Test started at: $start_time"
    
    # 统计变量
    local total_projects=0
    local successful_projects=0
    local failed_projects=0
    local projects_with_issues=()
    
    # 遍历configs目录下的所有子目录
    for project_dir in "$CONFIGS_DIR"/*/; do
        # 跳过非目录
        [ ! -d "$project_dir" ] && continue
        
        project_name=$(basename "$project_dir")
        config_file="${project_dir}config.json"
        
        # 检查config.json是否存在
        if [ ! -f "$config_file" ]; then
            log_file "Config file not found for $project_name, skipping: $config_file"
            continue
        fi
        
        total_projects=$((total_projects + 1))
        
        log_file "------------------------------------------"
        log_file "Processing project $total_projects: $project_name"
        log_file "------------------------------------------"
        
        # 1. 确保基线文件存在
        if ! ensure_baseline "$project_dir" "$config_file"; then
            # ensure_baseline 内部已经记录了详细错误和失败日志
            failed_projects=$((failed_projects + 1))
            projects_with_issues+=("$project_name (baseline generation failed)")
            continue
        fi
        
        # 2. 使用最新版本扫描项目
        local scan_result=$(scan_project "$engine_path" "$version" "$project_dir" "$config_file")
        if [ $? -ne 0 ] || [ -z "$scan_result" ]; then
            # scan_project 内部已经处理了失败日志和清理
            failed_projects=$((failed_projects + 1))
            projects_with_issues+=("$project_name (scan failed)")
            continue
        fi
        
        # 3. 对比基线
        local baseline_file="${project_dir}baseline.json"
        local safe_project_name=$(sanitize_project_name "$project_name")
        local project_comparison_dir="${REPORT_DIR}/${safe_project_name}/comparison"
        mkdir -p "$project_comparison_dir"
        # 报告文件名以 comparison- 开头，便于 report_viewer.yak 识别
        local comparison_report="${project_comparison_dir}/comparison-$(date '+%Y%m%d-%H%M%S').json"
        local compare_script="${WORK_DIR}/${APP_PATH}/baseline_compare.yak"
        
        log_file "Comparing with baseline for $project_name..."
        local compare_log="${SERVICE_DIR}/compare-${safe_project_name}-$(date '+%Y%m%d-%H%M%S').tmp.log"
        
        "$engine_path" "$compare_script" \
            --baseline "$baseline_file" \
            --current "$scan_result" \
            --output "$comparison_report" \
            --tolerance 10 \
            > "$compare_log" 2>&1
        
        local compare_exit=$?
        cat "$compare_log" >> "$LOG_FILE"
        
        if [ $compare_exit -eq 0 ]; then
            log_file "✓ $project_name: Baseline comparison PASSED"
            successful_projects=$((successful_projects + 1))
            rm -f "$compare_log"
        else
            log_error "✗ $project_name: Baseline comparison FAILED (exit code: $compare_exit)"
            # 保存对比失败日志
            save_comparison_failure_log "$project_name" "$version" "$compare_log" "$baseline_file" "$scan_result" "$comparison_report"
            rm -f "$compare_log"
            failed_projects=$((failed_projects + 1))
            projects_with_issues+=("$project_name (baseline mismatch)")
        fi
    done
    
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 输出汇总到文件
    log_file "=========================================="
    log_file "Benchmark Summary"
    log_file "=========================================="
    log_file "Test Duration: $start_time -> $end_time"
    log_file "Total Projects: $total_projects"
    log_file "Successful: $successful_projects"
    log_file "Failed: $failed_projects"
    
    if [ ${#projects_with_issues[@]} -gt 0 ]; then
        log_file "Projects with issues:"
        for issue in "${projects_with_issues[@]}"; do
            log_file "  - $issue"
        done
    fi
    
    # 更新配置
    update_config "last_run_time" "$start_time"
    
    if [ $failed_projects -eq 0 ]; then
        update_config_bool "last_run_success" "true"
        update_config "last_run_error" ""
        
        local total_runs=$(read_config "total_runs")
        if [ -z "$total_runs" ]; then
            total_runs=0
        fi
        total_runs=$((total_runs + 1))
        update_config_number "total_runs" "$total_runs"
        
        return 0
    else
        update_config_bool "last_run_success" "false"
        update_config "last_run_error" "$failed_projects/$total_projects projects failed"
        return 1
    fi
}

# ============= 清理旧引擎 =============
cleanup_old_engines() {
    log_file "Cleaning up old engine versions..."
    
    # 保留最新的 3 个版本
    local keep_count=3
    local engines=($(ls -t "$ENGINE_DIR"/yak-* 2>/dev/null || true))
    local engine_count=${#engines[@]}
    
    if [ "$engine_count" -le "$keep_count" ]; then
        log_file "No old engines to clean up (total: $engine_count)"
        return
    fi
    
    log_file "Found $engine_count engine versions, keeping latest $keep_count"
    
    for ((i=$keep_count; i<$engine_count; i++)); do
        local engine_to_remove="${engines[$i]}"
        log_file "Removing old engine: $engine_to_remove"
        rm -f "$engine_to_remove"
    done
}

# ============= 清理旧的失败日志 =============
cleanup_old_failure_logs() {
    # 保留最近 30 天的失败日志
    local keep_days=30
    
    if [ -d "$FAILURE_LOG_DIR" ]; then
        local old_logs=$(find "$FAILURE_LOG_DIR" -name "*.log" -mtime +$keep_days 2>/dev/null)
        if [ -n "$old_logs" ]; then
            log_file "Cleaning up failure logs older than $keep_days days..."
            echo "$old_logs" | xargs rm -f 2>/dev/null
        fi
    fi
}

# ============= 主逻辑 =============
main() {
    # 首先确保服务目录存在（用于日志）
    mkdir -p "$SERVICE_DIR"
    mkdir -p "$ENGINE_DIR"
    mkdir -p "$REPORT_DIR"
    mkdir -p "$FAILURE_LOG_DIR"
    
    # 检查锁文件，避免重复执行
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE")
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_warn "Another instance is running (PID: $lock_pid), exiting"
            exit 0
        else
            log_file "Stale lock file found, removing"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 创建锁文件
    echo $$ > "$LOCK_FILE"
    
    # 确保退出时删除锁文件
    trap "rm -f '$LOCK_FILE'" EXIT
    
    # 初始化服务（静默）
    init_service
    
    # 更新检查时间
    update_config "last_check_time" "$(date '+%Y-%m-%d %H:%M:%S')"
    
    # 获取当前配置的版本
    local current_version=$(read_config "current_version")
    log_file "Current engine version in config: ${current_version:-'(empty)'}"
    
    # 获取最新版本
    local latest_version=$(get_latest_version)
    if [ -z "$latest_version" ]; then
        # 网络错误已经在 get_latest_version 中输出到 journalctl
        update_config "last_run_error" "Failed to fetch latest version"
        exit 0
    fi
    
    # 判断是否需要更新
    local need_update=false
    if [ -z "$current_version" ]; then
        log_file "No version configured, will download latest version"
        need_update=true
    elif [ "$current_version" != "$latest_version" ]; then
        log_file "Version mismatch: current=$current_version, latest=$latest_version"
        need_update=true
    else
        # 版本相同，静默退出（只写文件日志）
        log_file "Version check OK: $current_version (up to date)"
        exit 0
    fi
    
    # 有新版本，输出到 journalctl
    if [ -z "$current_version" ]; then
        log_info "New version detected: $latest_version (first run)"
    else
        log_info "New version detected: $latest_version (current: $current_version)"
    fi
    
    # 下载引擎
    local engine_path=$(download_engine "$latest_version")
    if [ $? -ne 0 ] || [ -z "$engine_path" ]; then
        # 下载错误已经在 download_engine 中输出到 journalctl
        update_config "last_run_error" "Failed to download engine version $latest_version"
        exit 0
    fi
    
    # 注意：不要在这里更新版本配置！
    # 只有在基准测试成功完成后才更新版本，避免中断后无法重试
    update_config "engine_path" "$engine_path"
    
    log_info "Starting benchmark with engine $latest_version..."
    
    # 执行基准测试
    if run_benchmark "$engine_path" "$latest_version"; then
        # 只有在基准测试成功后才更新版本配置
        # 这样如果测试被中断，下次运行时会重新执行
        update_config "current_version" "$latest_version"
        
        # 清理旧引擎和旧失败日志
        cleanup_old_engines
        cleanup_old_failure_logs
        
        # 获取统计信息
        local total_runs=$(read_config "total_runs")
        log_info "Benchmark completed: all projects passed (total runs: $total_runs)"
        exit 0
    else
        # 获取失败信息
        local last_error=$(read_config "last_run_error")
        log_error "Benchmark failed: $last_error"
        log_error "Check failure logs: $FAILURE_LOG_DIR"
        # 不要 exit 1，让 systemd 认为服务正常结束
        # 不更新 current_version，下次定时器触发时会重试
        exit 0
    fi
}

# 执行主函数
main "$@"
