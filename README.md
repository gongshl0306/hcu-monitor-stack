# hcu-observability

海光 DCU/HCU 监控体系 —— **一个仓库，两种角色，离线优先**，用于统一部署与分发。

采集 → 存储 → 可视化 → 告警 全闭环：

```
GPU 计算节点(有 HCU)                中心节点(无 DCU 的虚拟机即可)
┌─────────────────────┐            ┌──────────────────────────────────┐
│  hcu-exporter :16080 │  scrape   │  Prometheus :9090                 │
│  (docker, 24 精选指标)│ ────────► │  Alertmanager :9093               │
└─────────────────────┘  (内网直连) │  Grafana      :3000               │
                                    └──────────────────────────────────┘
```

- **中心节点**：跑 Prometheus + Alertmanager + Grafana，按 `nodes.yml` 里的 IP 拉取各 GPU 节点指标。
- **GPU 计算节点**：跑 `hcu-exporter` 容器，暴露本机 HCU 指标到 `:16080`。
- **离线优先**：镜像 tar 随仓库分发（`images/`），新机器无需外网/代理即可部署。

## 目录结构

```
hcu-observability/
├── deploy.sh                     # 一键部署脚本（入口）
├── nodes.yml                     # GPU 节点列表（HCU 采集目标来源）
├── sglang.yml                    # SGLang 服务接口列表（推理服务采集目标来源）
├── images/                       # 离线镜像 tar（.gitignore，随目录拷贝分发）
└── config/
    ├── center/                   # 中心节点
    │   ├── docker-compose.yml    #   Prometheus + Alertmanager + Grafana
    │   ├── prometheus/
    │   │   ├── prometheus.yml    #   采集配置（file_sd 读 targets/）
    │   │   ├── rules/hcu-alerts.yml   # 11 条 HCU 告警规则
    │   │   ├── rules/sglang-alerts.yml # 8 条 SGLang 告警规则
    │   │   └── targets/          #   由 deploy.sh 从 nodes.yml / sglang.yml 生成
    │   ├── alertmanager/alertmanager.yml
    │   └── grafana/              #   数据源 + 4 个 dashboard 自动发现（含 SGLang）
    └── gpu-node/
        └── gpu-node.env          # exporter 运行参数（含 24 精选指标）
```

## 快速开始

### 0. 准备镜像（在已构建好镜像的机器上，一次性）

```bash
bash deploy.sh pack-images
# 生成 images/*.tar（4 个镜像各一个 tar）
```

> 若目标机器能联网且有代理，可跳过离线 tar，直接 `docker pull`（见文末「在线拉取」）。

### 1. 部署中心节点（无 DCU 的虚拟机）

```bash
# 把整个仓库拷到中心节点
bash deploy.sh center
```

自动完成：加载镜像 → 建数据目录并修属主 → 从 `nodes.yml` 生成采集目标 → 起栈 → 验证。

访问：
- Grafana `http://<中心IP>:3000`（admin / admin，**生产请改密码**）
- Prometheus `http://<中心IP>:9090`
- Alertmanager `http://<中心IP>:9093`

### 2. 部署 GPU 计算节点（每台有 HCU 的机器）

```bash
# 把整个仓库拷到该 GPU 节点
bash deploy.sh gpu-node
```

自动完成：加载镜像 → 检查驱动/设备 → 起 exporter（24 精选指标）→ 验证 `/metrics`。

### 3. 把 GPU 节点接入中心

```bash
# 在中心节点：编辑 nodes.yml，每行一个 <GPU节点IP>:16080
# 然后：
bash deploy.sh add-node
```

`add-node` 重新生成采集目标并热加载 Prometheus（file_sd 30s 内也会自动刷新）。

### 4. 查看

打开 Grafana，`HCU Exporter` dashboard 已自动导入，按 `node` 标签过滤各节点。

## SGLang 推理服务监控

监控 SGLang 推理服务（吞吐 / 延迟 / KV cache / 排队 / 投机解码等），方式与 GPU 节点相同：**填接口列表 → 生成 file_sd 目标 → 热加载**。

### 前提：服务开启 metrics

SGLang 启动参数加 `--enable-metrics`，`/metrics` 就暴露在**服务端口**上（如 `:8000/metrics`）。
验证：`curl http://<服务IP>:8000/metrics | grep sglang:`

### 接入步骤

```bash
# 1) 中心节点：编辑 sglang.yml，每行一个 <服务IP>:<端口>
# 2) 中心节点：
bash deploy.sh sglang
# 3) Grafana 打开 "SGLang Inference Monitor" dashboard（自动导入）
```

### 面板内容（15 个）

- **概览**：服务状态 / 运行中请求 / 排队请求 / KV cache 使用率 / 吞吐 / 缓存命中率
- **延迟**：TTFT P50/P90/P99、端到端延迟 P50/P90/P99、排队等待 P99
- **负载**：运行/排队请求数、KV cache tokens、prompt/generation token 速率
- **质量**：ITL P99、投机解码接受率（EAGLE）、中止/重退请求

### 告警规则（6 条，`config/center/prometheus/rules/sglang-alerts.yml`）

| 规则 | 级别 | 条件 |
|------|------|------|
| SGLangDown | critical | 服务离线 1m |
| SGLangQueueBacklog | warning | 排队 >32 持续 5m |
| SGLangRunningReqsHigh | warning | 运行中 >128 持续 5m |
| SGLangKVCacheHigh | warning | token_usage >0.9 持续 5m |
| SGLangTTFTHigh | warning | TTFT P99 >3s 持续 10m |
| SGLangE2ELatencyHigh | warning | E2E P99 >60s 持续 10m |
| SGLangAbortedRequests | warning | 5m 内有请求被中止 |
| SGLangSpecAcceptRateLow | warning | 投机接受率 <0.3 持续 30m |

## 常用命令

| 命令 | 作用 |
|------|------|
| `bash deploy.sh center` | 部署中心监控栈 |
| `bash deploy.sh gpu-node` | 部署 GPU 节点采集端 |
| `bash deploy.sh add-node` | 中心节点：从 nodes.yml 重新生成 HCU 目标 + 热加载 |
| `bash deploy.sh sglang` | 中心节点：从 sglang.yml 生成 SGLang 目标 + 热加载 |
| `bash deploy.sh status` | 查看本机容器 / 目标 / 指标状态 |
| `bash deploy.sh stop` | 停止本机相关容器 |
| `bash deploy.sh pack-images` | 打包离线镜像 tar 到 `images/` |

## 关键设计点

### 为什么 GPU 节点必须用「24 精选指标」

`hcu-exporter` 内置看门狗：**单轮采集超 60s 未更新即 `os.Exit(1)`**。
默认 `medium`（81 指标）/`high` 在 **8 卡节点**下单轮约 60s，会被反复杀掉。
`config/gpu-node/gpu-node.env` 里的 `ENABLE_METRICS` 精选 24 个指标（覆盖全部告警规则 + 面板核心），8 卡实测单轮约 5s，稳定运行。
**不要**改回 `METRICS_LEVEL=medium/high`。

### 面板里 `vhcu_*`（虚拟卡）为什么是 No data

`HCU Cluster Monitor` 里的虚拟卡面板（`vhcu_utilizationrate` / `vhcu_usedmemory_bytes` / `vhcu_temp` / `vhcu_count`）
只在 **MIG/虚拟化** 场景下有数据。裸机（未开 MIG）没有虚拟卡，这些面板 No data 属**正常现象**，不是故障。

### 中心节点与 GPU 节点「不通」怎么办

- **同一内网可直连**（本仓库默认场景）：`nodes.yml` 写各 GPU 节点内网 IP，Prometheus 直接 scrape。
- **中心与某 GPU 节点同机**：该行写 `host.docker.internal:16080`（compose 已映射到宿主机网关）。
- **跨网段/需打通**：先保证中心节点能 `curl <GPU节点IP>:16080/metrics`（防火墙放行 16080），再填 `nodes.yml`。

### 离线 vs 在线

- **离线（默认）**：`images/` 里有 tar，`deploy.sh` 自动 `docker load`。
- **在线**：删掉 `images/` 的 tar，在 `deploy.sh` 的 `ensure_image` 里取消 `docker pull` 注释，并把镜像名改成可达的 registry 地址。

## 告警规则（11 条）

| 规则 | 级别 | 含义 |
|------|------|------|
| HCUHealthCheckFailed | critical | 健康检查失败 |
| HCUCriticalTemp | critical | 温度超临界 |
| HCUUncorrectableECC | critical | 不可纠正 ECC 错误 |
| HCUProcessIdle | critical | 有进程但卡空闲（疑似卡死） |
| HCUExporterDown | critical | 采集端离线 |
| HCUHighTemp | warning | 温度偏高 |
| HCUThrottling | warning | 降频 |
| HCUCorrectableECC | warning | 可纠正 ECC 错误 |
| HCUBadPages | warning | 坏页 |
| HCULowPowerWithProcess | warning | 有进程但功耗异常低 |
| HCUExporterSlowScrape | warning | 采集变慢 |

告警通道在 `config/center/alertmanager/alertmanager.yml` 配置（默认 webhook，可改邮件/钉钉）。

## 迁移 / 扩容

- **加 GPU 节点**：新节点 `bash deploy.sh gpu-node` → 中心 `nodes.yml` 加一行 → `bash deploy.sh add-node`。
- **迁移中心节点**：新中心机 `bash deploy.sh center`（全新开始，不保留旧数据）；各 GPU 节点无需改动，只需确认 `nodes.yml` 指向新中心（GPU 节点是被动被 scrape，不感知中心位置）。
