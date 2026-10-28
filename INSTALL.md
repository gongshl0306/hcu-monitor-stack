# HCU + SGLang 监控体系 —— 新集群安装说明（交接文档）

本文档面向**执行部署的 agent/工程师**，目标：在一套新集群里从零搭建完整的
DCU/HCU 硬件监控 + SGLang 推理服务监控（采集→存储→可视化→告警闭环）。
所有步骤均可脚本化执行，关键验证点已标注。

---

## 0. 体系总览

```
GPU 计算节点(有 HCU)                        中心节点(无 HCU 的 VM 即可)
┌──────────────────────────────┐           ┌─────────────────────────────────┐
│ hcu-exporter :16080 (docker) │  scrape   │ Prometheus     :9090            │
│ SGLang 服务 :8000~ (host)    │ ────────► │ Alertmanager   :9093            │
│   (需 --enable-metrics)      │  内网直连  │ Grafana        :3000            │
└──────────────────────────────┘           └─────────────────────────────────┘
```

- **中心节点**：跑 Prometheus + Alertmanager + Grafana（docker compose），按 `nodes.yml` /
  `sglang.yml` 里的目标拉取指标。
- **GPU 计算节点**：跑 `hcu-exporter` 容器（24 精选指标）；SGLang 服务需带
  `--enable-metrics` 启动（`/metrics` 在服务端口上）。
- **离线优先**：镜像 tar 在 `images/` 里，新机器无需外网/代理。

## 1. 传输清单（从源环境拷到新集群）

| # | 内容 | 源路径 | 大小 | 必需 | 说明 |
|---|------|--------|------|------|------|
| 1 | 仓库本体（含 images/） | `hcu-monitor-stack-<日期>.tar.gz` | ~353M | ✅ | 一个包全包含：deploy.sh、config/、nodes.yml、sglang.yml、images/ 4 个镜像 tar、.git |
| 2 | （可选）单独镜像 tar | `images/*.tar` | 355M | 仅当仓库包没带 images/ 时 | prometheus/alertmanager/grafana/hcu-exporter 各一个 |

**推荐做法**：直接传仓库 tar 包（源环境用 `tar czf hcu-monitor-stack-$(date +%Y%m%d).tar.gz hcu-monitor-stack` 生成，
源环境 `/root/maintenance/` 下有现成的）。传输后核对 sha256。

仓库包内**不需要**传输的东西（新集群自己生成/已有）：
- `config/center/data/`（运行时数据，.gitignore，全新开始）
- 各 GPU 节点的 HCU 驱动（`/opt/hyhal`，节点出厂/装驱动时已有）
- SGLang 服务本身（新集群自己的业务）

## 2. 前置条件

### 中心节点（1 台，无 HCU 的 VM 即可）
- [ ] Ubuntu 20.04+ / 内核 5.x+
- [ ] Docker + docker compose v2（`docker compose version` 能输出版本）
- [ ] 用户有 docker 权限（root 或 docker 组；非 root 时脚本自动 chmod 777 数据目录）
- [ ] 端口空闲：3000 / 9090 / 9093
- [ ] 到各 GPU 节点 16080 端口、各 SGLang 服务端口**网络可达**（防火墙放行）
- [ ] 磁盘 ≥ 20G（镜像 + 30 天 TSDB）

### GPU 计算节点（N 台，有 HCU）
- [ ] HCU 驱动已装：`/opt/hyhal` 存在、`/dev/kfd` 存在（`hy-smi` 能列出卡）
- [ ] Docker 已装
- [ ] 需要 root（exporter 容器要 `--privileged` + 挂 HCU 设备）
- [ ] 到中心节点网络可达（被动被 scrape，只需中心→节点方向通）

### SGLang 服务（如有）
- [ ] 启动参数带 `--enable-metrics`（**没有这个参数 /metrics 是 404**）
- [ ] 记录每个实例的 `<IP>:<端口>`（host 网络时就是宿主机 IP + 服务端口）

## 3. 部署步骤

### 步骤 1：所有节点解压仓库

```bash
tar xzf hcu-monitor-stack-<日期>.tar.gz -C /root/maintenance/
cd /root/maintenance/hcu-monitor-stack
```

### 步骤 2：部署中心节点

```bash
bash deploy.sh center
```

脚本自动完成：加载 3 个镜像 → 建数据目录并授权 → 从 nodes.yml/sglang.yml 生成
file_sd 目标 → `docker compose up -d` → 验证 Prometheus ready。

**验证**：
```bash
curl -sf http://127.0.0.1:9090/-/ready && echo OK
docker ps --filter name=hcu-   # 3 个容器 Up
```

### 步骤 3：部署 GPU 节点（每台）

```bash
bash deploy.sh gpu-node
```

脚本自动完成：加载 hcu-exporter 镜像 → 检查 /opt/hyhal、/dev/kfd → 起容器
（24 精选指标，**不要改回 METRICS_LEVEL=medium/high**，8 卡会被 60s 看门狗杀）→ 验证。

**验证**：
```bash
curl -sf http://127.0.0.1:16080/metrics | grep -c '^hcu_'   # 应 >100
docker ps --filter name=hcu-exporter
```

> 注意：脚本验证窗口 90s。首轮采集含 DCGM 初始化，30~60s 才出指标属正常。

### 步骤 4：填采集目标（中心节点）

编辑 `nodes.yml`（GPU 节点）和 `sglang.yml`（SGLang 服务），然后：

```bash
bash deploy.sh add-node    # 重新生成 HCU 目标 + 热加载
bash deploy.sh sglang      # 重新生成 SGLang 目标 + 热加载
```

`sglang.yml` 推荐用命名形式（Grafana 图例显示友好）：
```yaml
targets:
  - target: "10.x.x.1:8000"
    server: "gpu-server01-1"
  - target: "10.x.x.1:8001"
    server: "gpu-server01-2"
```

### 步骤 5：端到端验证（中心节点）

```bash
# 1) 目标全 up
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -m json.tool | grep -E '"(scrapeUrl|health)"'

# 2) HCU 指标可查（应返回各节点卡数条序列）
curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=count(hcu_temp)'

# 3) SGLang 指标可查（注意：Prometheus 里指标名是下划线 sglang_xxx，
#    冒号形式 sglang:xxx 查不到——Prometheus 入库时清洗了冒号）
curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=sglang_num_running_reqs'

# 4) 告警规则加载（应看到 hcu-* 和 sglang-* 组）
curl -s http://127.0.0.1:9090/api/v1/rules | python3 -c "import json,sys; [print(g['name'], len(g['rules'])) for g in json.load(sys.stdin)['data']['groups']]"

# 5) Grafana
#    http://<中心IP>:3000  (admin/admin —— 生产必须改密码)
#    应有 4 个 dashboard：HCU Exporter / HCU Cluster Monitor / HCU K8S Exporter / SGLang Inference Monitor
```

## 4. 已知坑（务必阅读）

1. **8 卡看门狗**：hcu-exporter 单轮采集超 60s 会 `os.Exit(1)`。默认 medium/high
   指标档在 8 卡节点单轮 ~60s 必死。必须用 `gpu-node.env` 里的 24 精选指标
   （`ENABLE_METRICS`，单轮 ~5s）。**不要**改成 `METRICS_LEVEL`。
2. **SGLang 指标名冒号被清洗**：端点输出 `sglang:xxx`，Prometheus 入库后是
   `sglang_xxx`。PromQL/dashboard/告警一律用下划线；只有 curl 原始端点时是冒号。
3. **SGLang 必须 `--enable-metrics`**：没加该参数 `/metrics` 返回 404，目标 down。
   加参数需要重启服务（模型重载几分钟，挑业务窗口）。
4. **bind mount 换 inode**：改 `prometheus.yml` 后 `POST /-/reload` 可能读不到新内容
   （文件被替换时 inode 变了），要 `docker compose restart prometheus`。
   而 `targets/*.json`（file_sd）和告警规则目录是目录级挂载，reload 即可。
5. **数据目录属主**：prometheus/alertmanager 容器以 nobody(65534) 跑、grafana 以
   472 跑。root 部署时脚本自动 chown；非 root 时自动 chmod 777。
6. **vhcu_* 面板 No data 是正常的**：HCU Cluster Monitor 里虚拟卡面板只在 MIG/
   虚拟化场景有数据，裸机为空不是故障。
7. **Grafana 文件 provisioning 按 version 判断更新**：UI 里改过 dashboard 后
   （version 变高），再同步文件不会覆盖。强制覆盖用 API：
   ```bash
   curl -u admin:<密码> -X POST -H "Content-Type: application/json" \
     -d @<(python3 -c "import json; d=json.load(open('config/center/grafana/dashboards/sglang-inference-dashboard.json')); print(json.dumps({'dashboard':d,'overwrite':True}))") \
     http://127.0.0.1:3000/api/dashboards/db
   ```
8. **中心与 GPU 同机**时，nodes.yml 写 `host.docker.internal:16080`（compose 已映射
   到宿主机网关），**不能**写 127.0.0.1（那是 prometheus 容器自己的回环）。
9. **告警通道**：`alertmanager.yml` 默认 webhook 指向 `127.0.0.1:8060`（钉钉转发），
   新集群没有该服务时告警只到 Alertmanager UI（http://<中心IP>:9093），不报错。
   按新集群的告警通道改 `receivers`。
10. **Grafana 默认密码 admin/admin**，生产必须改（`GF_SECURITY_ADMIN_PASSWORD`
    在 docker-compose.yml 里，改完 `docker compose up -d` 重建容器）。

## 5. 日常运维

| 操作 | 命令（中心节点） |
|------|------|
| 加 GPU 节点 | 节点上 `bash deploy.sh gpu-node` → 中心 `nodes.yml` 加一行 → `bash deploy.sh add-node` |
| 加 SGLang 实例 | `sglang.yml` 加两行（target+server）→ `bash deploy.sh sglang` |
| 看状态 | `bash deploy.sh status` |
| 停栈 | `bash deploy.sh stop` |
| 热加载 | `curl -X POST http://127.0.0.1:9090/-/reload` |
| 告警查看 | http://<中心IP>:9093 |

## 6. 验收标准（部署完成的定义）

- [ ] 中心节点 3 容器 Up，`/-/ready` 返回 OK
- [ ] 所有 GPU 节点 hcu-exporter Up，`/metrics` 有 hcu_ 指标
- [ ] Prometheus targets：hcu-exporter job 全 up
- [ ] Prometheus targets：sglang job 全 up（前提：服务都开了 --enable-metrics）
- [ ] `count(hcu_temp)` 返回序列数 = 总卡数
- [ ] `sglang_num_running_reqs` 返回序列数 = SGLang 实例数
- [ ] 告警规则组全部加载（hcu-hardware/hcu-workload/hcu-self-monitor/sglang-*）
- [ ] Grafana 4 个 dashboard 可见，SGLang 面板图例显示 server 名（如 gpu-server01-1）
- [ ] Grafana 密码已改
