#!/usr/bin/env bash
# =============================================================================
# HCU 可观测体系 —— 一键部署脚本
#
# 一个仓库，两种角色，离线优先（镜像 tar 随仓库分发，新机器无需外网/代理）。
#
#   中心节点（无 DCU 的虚拟机即可）：跑 Prometheus + Alertmanager + Grafana
#   GPU 计算节点（有 HCU 的机器）：  跑 hcu-exporter 采集端
#
# 用法：
#   bash deploy.sh center      # 在本机部署中心监控栈
#   bash deploy.sh gpu-node    # 在本机部署 hcu-exporter（GPU 节点）
#   bash deploy.sh add-node    # 中心节点：从 nodes.txt 重新生成采集目标并热加载
#   bash deploy.sh status      # 查看本机部署状态
#   bash deploy.sh stop        # 停止本机相关容器
#
# 典型流程（跨机）：
#   1) 把整个仓库拷到中心节点，bash deploy.sh center
#   2) 把整个仓库拷到每台 GPU 节点，bash deploy.sh gpu-node
#   3) 在中心节点编辑 nodes.txt 填各 GPU 节点 IP，bash deploy.sh add-node
#   4) 打开 http://<中心IP>:3000 看 Grafana
#
# 镜像分发（离线）：
#   本脚本默认从 images/ 目录 docker load 镜像。images/ 里的 tar 由
#   `bash deploy.sh pack-images` 在已构建好的机器上生成（见文末）。
# =============================================================================
set -euo pipefail

# ===== 路径与常量 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENTER_DIR="${SCRIPT_DIR}/config/center"
GPU_DIR="${SCRIPT_DIR}/config/gpu-node"
IMAGES_DIR="${SCRIPT_DIR}/images"
NODES_FILE="${SCRIPT_DIR}/nodes.txt"
DATA_DIR="${CENTER_DIR}/data"

# 镜像名（与 images/ 里 tar 的 tag 对应）
IMG_PROM="prom/prometheus:v2.53.0"
IMG_AM="prom/alertmanager:v0.27.0"
IMG_GRAFANA="grafana/grafana:11.1.0"
IMG_EXPORTER="hcu-exporter:v3.0.0"

# 中心栈容器名
C_PROM="hcu-prometheus"; C_AM="hcu-alertmanager"; C_GRAFANA="hcu-grafana"
C_EXPORTER="hcu-exporter"

# ===== 小工具 =====
log()  { echo -e "\033[1;32m[OK]\033[0m  $*"; }
info() { echo -e "\033[1;36m[..]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 docker"
  docker info >/dev/null 2>&1 || die "docker 守护进程不可用（当前用户无权限？试试 sudo）"
}

# 离线优先：镜像不存在则从 images/ 加载；加载后仍不存在则报错
ensure_image() {
  local img="$1" tar
  if docker image inspect "$img" >/dev/null 2>&1; then
    return 0
  fi
  # 在 images/ 里找包含该镜像的 tar（文件名含镜像名主干）
  local key; key="$(echo "$img" | sed 's#/#-#g; s#:#-#g')"
  tar="$(ls "${IMAGES_DIR}"/*"${key}"*.tar 2>/dev/null | head -n1 || true)"
  if [ -n "${tar}" ]; then
    info "本地无镜像 ${img}，从 ${tar} 加载…"
    docker load -i "${tar}" >/dev/null
  fi
  docker image inspect "$img" >/dev/null 2>&1 \
    || die "镜像 ${img} 不可用：images/ 下没有对应 tar，且本地未构建。请先在构建机上执行 bash deploy.sh pack-images"
}

# 从 nodes.txt 生成 Prometheus file_sd 目标文件
gen_targets() {
  local out="$1"
  [ -f "${NODES_FILE}" ] || die "找不到 ${NODES_FILE}"
  {
    echo "["
    local first=1
    while IFS= read -r line; do
      # 去掉行内注释与首尾空白
      line="${line%%#*}"
      line="$(echo "${line}" | xargs || true)"
      [ -z "${line}" ] && continue
      # 补默认端口
      case "${line}" in
        *:*) : ;;
        *)   line="${line}:16080" ;;
      esac
      [ "${first}" = "0" ] && echo ","
      first=0
      printf '  {"targets":["%s"],"labels":{"node":"%s"}}' \
        "${line}" "$(echo "${line}" | cut -d: -f1)"
    done < "${NODES_FILE}"
    echo
    echo "]"
  } > "${out}"
  info "已生成采集目标：${out}"
  cat "${out}"
}

# =============================================================================
# 中心节点
# =============================================================================
deploy_center() {
  require_docker
  info "部署中心监控栈（Prometheus + Alertmanager + Grafana）"

  # 1) 镜像
  ensure_image "${IMG_PROM}"
  ensure_image "${IMG_AM}"
  ensure_image "${IMG_GRAFANA}"

  # 2) 数据目录 + 属主（容器以 nobody(65534)/grafana(472) 运行，目录须可写）
  #    root：chown 到容器 uid（干净）；非 root（docker 组用户）：chmod 777 兜底
  mkdir -p "${DATA_DIR}/prometheus" "${DATA_DIR}/alertmanager" "${DATA_DIR}/grafana"
  if [ "$(id -u)" = "0" ]; then
    chown -R 65534:65534 "${DATA_DIR}/prometheus" "${DATA_DIR}/alertmanager"
    chown -R 472:472     "${DATA_DIR}/grafana"
  else
    chmod -R 777 "${DATA_DIR}/prometheus" "${DATA_DIR}/alertmanager" "${DATA_DIR}/grafana"
    warn "非 root 用户：数据目录用 chmod 777 授权（容器 uid 65534/472 需可写）"
  fi
  log "数据目录就绪：${DATA_DIR}"

  # 3) 生成采集目标（file_sd）
  gen_targets "${CENTER_DIR}/prometheus/targets/hcu-nodes.json"

  # 4) 起栈
  cd "${CENTER_DIR}"
  docker compose down 2>/dev/null || true
  docker compose up -d
  log "中心栈已启动"

  # 5) 验证
  local ok=0
  for i in $(seq 1 30); do
    sleep 1
    if curl -sf "http://127.0.0.1:9090/-/ready" >/dev/null 2>&1; then ok=1; break; fi
  done
  if [ "${ok}" = "1" ]; then
    log "Prometheus 就绪 (http://127.0.0.1:9090)"
  else
    warn "Prometheus 30s 内未就绪，请检查 docker logs ${C_PROM}"
  fi

  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "============================================================"
  echo "  中心节点部署完成"
  echo "  Grafana        http://${ip:-<本机IP>}:3000   (admin / admin)"
  echo "  Prometheus     http://${ip:-<本机IP>}:9090"
  echo "  Alertmanager   http://${ip:-<本机IP>}:9093"
  echo
  echo "  下一步："
  echo "    1) 在每台 GPU 节点执行: bash deploy.sh gpu-node"
  echo "    2) 编辑 nodes.txt 填各 GPU 节点 IP"
  echo "    3) 执行: bash deploy.sh add-node"
  echo "============================================================"
}

# =============================================================================
# GPU 计算节点
# =============================================================================
deploy_gpu_node() {
  require_docker
  info "部署 hcu-exporter（GPU 计算节点采集端）"

  # 1) 镜像
  ensure_image "${IMG_EXPORTER}"

  # 2) 驱动检查
  [ -d /opt/hyhal ] || warn "未找到 /opt/hyhal（HCU 驱动目录），exporter 可能无法采集"
  [ -e /dev/kfd ]   || warn "未找到 /dev/kfd（HCU 设备），exporter 可能无法采集"

  # 3) 读取参数
  local PORT=16080 CONNECT_K8S=false ALLOWED_IPS="" ENABLE_METRICS=""
  if [ -f "${GPU_DIR}/gpu-node.env" ]; then
    # shellcheck disable=SC1090
    source "${GPU_DIR}/gpu-node.env"
  fi
  [ -n "${ENABLE_METRICS}" ] || die "gpu-node.env 未配置 ENABLE_METRICS（8 卡节点必须用精选指标，否则会被看门狗杀掉）"

  # 4) 幂等：清理旧容器
  docker rm -f "${C_EXPORTER}" 2>/dev/null || true

  # 5) 起容器
  docker run --name "${C_EXPORTER}" -d --restart unless-stopped --privileged \
    --device=/dev/kfd \
    --device=/dev/mkfd \
    --device=/dev/dri \
    -v /etc/vdev:/etc/vdev \
    -v /etc/hostname:/etc/hostname \
    -v /opt/hyhal:/opt/hyhal \
    -p "${PORT}:${PORT}" \
    -e CONNECT_K8S="${CONNECT_K8S}" \
    -e ENABLE_METRICS="${ENABLE_METRICS}" \
    -e ALLOWED_IPS="${ALLOWED_IPS}" \
    "${IMG_EXPORTER}"
  log "hcu-exporter 已启动（端口 ${PORT}）"

  # 6) 验证（精选指标 ~5s/轮，留 30s 余量）
  local ok=0
  for i in $(seq 1 30); do
    sleep 1
    if curl -sf "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q '^hcu_'; then ok=1; break; fi
  done
  if [ "${ok}" = "1" ]; then
    log "exporter 正常，指标已暴露"
  else
    die "exporter 30s 内未返回 hcu_ 指标，请检查 docker logs ${C_EXPORTER}"
  fi

  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "============================================================"
  echo "  GPU 节点部署完成"
  echo "  本机采集端: http://${ip:-<本机IP>}:${PORT}/metrics"
  echo
  echo "  下一步（在中心节点）："
  echo "    把 ${ip:-<本机IP>}:${PORT} 加进 nodes.txt，然后 bash deploy.sh add-node"
  echo "============================================================"
}

# =============================================================================
# 中心节点：重新生成目标 + 热加载
# =============================================================================
add_node() {
  require_docker
  gen_targets "${CENTER_DIR}/prometheus/targets/hcu-nodes.json"
  # file_sd 30s 内自动刷新；这里主动 reload 立即生效
  if docker ps --format '{{.Names}}' | grep -qx "${C_PROM}"; then
    curl -sf -X POST "http://127.0.0.1:9090/-/reload" >/dev/null 2>&1 \
      && log "Prometheus 已热加载新目标" \
      || warn "reload 失败，file_sd 也会在 30s 内自动刷新"
  else
    warn "Prometheus 容器未运行，目标已写入文件，启动后自动生效"
  fi
}

# =============================================================================
# 状态 / 停止
# =============================================================================
status() {
  echo "===== 本机容器状态 ====="
  docker ps -a --filter "name=${C_PROM}" --filter "name=${C_AM}" \
    --filter "name=${C_GRAFANA}" --filter "name=${C_EXPORTER}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "（无相关容器）"
  echo
  if docker ps --format '{{.Names}}' | grep -qx "${C_PROM}"; then
    echo "===== Prometheus 目标 ====="
    curl -sf "http://127.0.0.1:9090/api/v1/targets" 2>/dev/null \
      | grep -oE '"(health|scrapeUrl)":"[^"]*"' | paste - - || echo "（Prometheus 未就绪）"
  fi
  if docker ps --format '{{.Names}}' | grep -qx "${C_EXPORTER}"; then
    echo
    echo "===== 本机 exporter 指标样例 ====="
    curl -sf "http://127.0.0.1:16080/metrics" 2>/dev/null | grep -E '^hcu_(temp|utilizationrate|health_status)' | head -n 8 || echo "（无 hcu_ 指标）"
  fi
}

stop() {
  require_docker
  info "停止本机相关容器"
  if [ -f "${CENTER_DIR}/docker-compose.yml" ]; then
    (cd "${CENTER_DIR}" && docker compose down 2>/dev/null || true)
  fi
  docker rm -f "${C_EXPORTER}" 2>/dev/null || true
  log "已停止"
}

# =============================================================================
# 打包镜像（在已构建好镜像的机器上执行，生成 images/ 下的离线 tar）
# =============================================================================
pack_images() {
  require_docker
  mkdir -p "${IMAGES_DIR}"
  # 每个镜像单独一个 tar，文件名含镜像名主干，便于 ensure_image 按名匹配
  local img
  for img in "${IMG_PROM}" "${IMG_AM}" "${IMG_GRAFANA}" "${IMG_EXPORTER}"; do
    local key; key="$(echo "${img}" | sed 's#/#-#g; s#:#-#g')"
    info "打包 ${img} → ${IMAGES_DIR}/${key}.tar"
    docker save "${img}" -o "${IMAGES_DIR}/${key}.tar"
  done
  log "镜像打包完成："
  ls -lh "${IMAGES_DIR}"/*.tar
  echo
  echo "把整个仓库（含 images/）拷到新机器即可离线部署。"
  echo "注意：images/ 已加入 .gitignore，不会进 git；分发时随仓库目录一起拷贝。"
}

# =============================================================================
# 入口
# =============================================================================
case "${1:-}" in
  center)     deploy_center ;;
  gpu-node)   deploy_gpu_node ;;
  add-node)   add_node ;;
  status)     status ;;
  stop)       stop ;;
  pack-images) pack_images ;;
  *)
    cat <<'USAGE'
HCU 可观测体系 —— 一键部署脚本

用法：
  bash deploy.sh center       在本机部署中心监控栈（Prometheus+Alertmanager+Grafana）
  bash deploy.sh gpu-node     在本机部署 hcu-exporter（GPU 计算节点采集端）
  bash deploy.sh add-node     中心节点：从 nodes.txt 重新生成采集目标并热加载
  bash deploy.sh status       查看本机容器 / 目标 / 指标状态
  bash deploy.sh stop         停止本机相关容器
  bash deploy.sh pack-images  打包离线镜像 tar 到 images/（在已构建镜像的机器上执行）

典型流程（跨机）：
  1) 中心节点:  bash deploy.sh center
  2) 各 GPU 节点: bash deploy.sh gpu-node
  3) 中心节点:  编辑 nodes.txt 填各 GPU 节点 IP，再 bash deploy.sh add-node
  4) 打开 http://<中心IP>:3000 看 Grafana
USAGE
    exit 1
    ;;
esac
