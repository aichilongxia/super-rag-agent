# SuperBizAgent 项目全貌导读 / SuperBizAgent Project Overview

> 基于 repo-guide skill 自动生成，代码证据截至 2026-06-07

---

## 1. 项目定位 / Project Positioning

**一句话**：面向企业运维场景的 AI 助手，将 RAG 知识库问答与 AIOps 自动诊断融合在同一服务中，实现"问答→检索→诊断→报告"全流程自动化。

**One-liner**: An enterprise AIOps assistant that unifies RAG-based knowledge Q&A and automated fault diagnosis into a single service, delivering end-to-end "query → retrieval → diagnosis → report" automation.

---

## 2. 架构总览 / Architecture Overview

### 2.1 系统分层图 / Layered Architecture

```mermaid
graph TB
    subgraph Client["客户端 / Client"]
        WEB["Web UI<br/>(static/index.html)"]
        CURL["cURL / API Consumer"]
    end

    subgraph FastAPI["FastAPI 主服务 :9900"]
        direction TB
        API["API 层<br/>chat / aiops / file / health"]
        SVC["Service 层<br/>RagAgent / AIOps / VectorIndex"]
        AGENT["Agent 层<br/>Planner / Executor / Replanner / MCP Client"]
        CORE["Core 层<br/>LLM Factory / Milvus Client"]
    end

    subgraph External["外部组件"]
        MILVUS["Milvus :19530<br/>(向量数据库)"]
        DASHSCOPE["DashScope<br/>(Qwen LLM + Embedding)"]
        MCP_CLS["MCP CLS Server :3000<br/>(日志查询)"]
        MCP_MON["MCP Monitor Server :8004<br/>(监控/工单)"]
    end

    WEB -->|HTTP/SSE| API
    CURL -->|HTTP/SSE| API
    API --> SVC
    SVC --> AGENT
    AGENT --> CORE
    CORE -->|pymilvus| MILVUS
    CORE -->|OpenAI-compatible API| DASHSCOPE
    AGENT -->|SSE/Streamable-HTTP| MCP_CLS
    AGENT -->|Streamable-HTTP| MCP_MON
```

### 2.2 运行时部署图 / Deployment Diagram

```mermaid
graph LR
    subgraph Host["主机 / Docker Host"]
        APP["python -m uvicorn app.main:app<br/>:9900"]
        CLS["python mcp_servers/cls_server.py<br/>:3000 (SSE)"]
        MON["python mcp_servers/monitor_server.py<br/>:8004 (Streamable-HTTP)"]
    end

    subgraph Docker["Docker Compose (vector-database.yml)"]
        MIL_STANDALONE["milvus-standalone :19530"]
        ETCD["etcd :2379"]
        MINIO["minio :9000"]
    end

    APP -->|TCP| MIL_STANDALONE
    APP -->|HTTP| CLS
    APP -->|HTTP| MON
    MIL_STANDALONE --> ETCD
    MIL_STANDALONE --> MINIO
```

### 2.3 核心数据流图 / Data Flow

```mermaid
flowchart LR
    subgraph Upload["文档上传链路"]
        U1["用户上传 .md/.txt"] --> U2["保存到 uploads/"]
        U2 --> U3["MarkdownHeaderTextSplitter<br/>+ RecursiveCharacterTextSplitter"]
        U3 --> U4["DashScope Embedding<br/>(text-embedding-v4, 1024d)"]
        U4 --> U5["写入 Milvus<br/>(collection: biz)"]
    end

    subgraph Query["知识检索链路"]
        Q1["用户问题"] --> Q2["Embedding 向量化"]
        Q2 --> Q3["Milvus similarity_search<br/>(L2, top_k=3)"]
        Q3 --> Q4["格式化 context"]
        Q4 --> Q5["注入 LLM prompt"]
    end
```

---

## 3. 核心调用链 / Core Call Chains

### 3.1 RAG 对话链路 / RAG Chat Flow

```mermaid
sequenceDiagram
    participant U as User
    participant API as /api/chat[_stream]
    participant RAG as RagAgentService
    participant LG as LangGraph Agent
    participant T as Tools (knowledge + MCP)
    participant LLM as ChatQwen

    U->>API: POST {Question, Id}
    API->>RAG: query / query_stream
    RAG->>RAG: _initialize_agent() (lazy)
    RAG->>LG: ainvoke / astream
    LG->>LLM: messages + tool_bindings
    LLM-->>LG: tool_calls[]
    LG->>T: invoke tools
    T-->>LG: tool results
    LG->>LLM: messages + tool results
    LLM-->>LG: final answer
    LG-->>RAG: result
    RAG-->>API: response / SSE chunks
    API-->>U: JSON / SSE stream
```

**关键文件 / Key Files**:
- 入口: `app/api/chat.py`
- 编排: `app/services/rag_agent_service.py`
- 工具: `app/tools/knowledge_tool.py`, `app/tools/time_tool.py`

### 3.2 AIOps 诊断链路 / AIOps Diagnosis Flow

```mermaid
stateDiagram-v2
    [*] --> Planner
    Planner --> Executor: plan[]
    Executor --> Replanner: past_steps += (task, result)
    Replanner --> Executor: action=continue / replan
    Replanner --> [*]: action=respond / plan 为空

    note right of Planner
        1. 查询知识库获取经验
        2. 获取可用工具列表
        3. LLM 生成步骤列表
    end note

    note right of Executor
        1. 取 plan[0]
        2. LLM + bind_tools 决定调用
        3. ToolNode 执行
        4. LLM 总结结果
    end note

    note right of Replanner
        决策优先级:
        respond > continue > replan
        强制限制: past_steps >= 8 → respond
    end note
```

**关键文件 / Key Files**:
- API: `app/api/aiops.py`
- 编排: `app/services/aiops_service.py`
- 状态定义: `app/agent/aiops/state.py`
- Planner: `app/agent/aiops/planner.py`
- Executor: `app/agent/aiops/executor.py`
- Replanner: `app/agent/aiops/replanner.py`

### 3.3 文档索引链路 / Document Indexing Flow

```mermaid
sequenceDiagram
    participant U as User
    participant API as /api/upload
    participant IDX as VectorIndexService
    participant SPL as DocumentSplitterService
    participant VSM as VectorStoreManager
    participant EMB as DashScopeEmbeddings
    participant MIL as Milvus

    U->>API: POST multipart/form-data
    API->>API: 验证 + 保存文件
    API->>IDX: index_single_file(path)
    IDX->>IDX: 读取文件内容
    IDX->>VSM: delete_by_source(path) [覆盖旧数据]
    IDX->>SPL: split_document(content, path)
    SPL-->>IDX: List[Document]
    IDX->>VSM: add_documents(docs)
    VSM->>EMB: embed_documents(texts)
    EMB-->>VSM: vectors[]
    VSM->>MIL: insert(ids, content, vectors, metadata)
    MIL-->>VSM: OK
    VSM-->>API: done
    API-->>U: 200 {filename, size}
```

### 3.4 MCP 工具接入链路 / MCP Tool Integration

```mermaid
flowchart TB
    subgraph App["FastAPI 主服务"]
        MCP_CLIENT["MultiServerMCPClient<br/>(singleton + retry interceptor)"]
        RETRY["retry_interceptor<br/>(指数退避, max_retries=3)"]
    end

    subgraph Servers["MCP Servers"]
        CLS["CLS Server<br/>SSE :3000"]
        MON["Monitor Server<br/>Streamable-HTTP :8004"]
    end

    MCP_CLIENT -->|tool_interceptors| RETRY
    MCP_CLIENT -->|SSE| CLS
    MCP_CLIENT -->|HTTP| MON

    CLS --- T1["get_current_timestamp"]
    CLS --- T2["search_log / search_service_logs"]
    CLS --- T3["analyze_log_pattern"]
    MON --- T4["query_cpu_metrics / query_memory_metrics"]
    MON --- T5["query_process_list"]
    MON --- T6["search_historical_tickets"]
    MON --- T7["get_service_info / list_all_services"]
```

---

## 4. 关键模块表 / Key Modules

| 模块 Module | 职责 Responsibility | 关键文件 Key File | 上下游依赖 Dependencies | 扩展点 Extension Points |
|---|---|---|---|---|
| 应用入口 Entry | 生命周期、路由注册、静态文件 | `app/main.py` | FastAPI, milvus_manager | 中间件、生命周期钩子 |
| 配置中心 Config | 环境变量 + MCP 服务器配置 | `app/config.py` | pydantic-settings, .env | 多环境配置、密钥管理 |
| RAG Agent | 对话编排、工具调用、会话记忆 | `app/services/rag_agent_service.py` | LangGraph, ChatQwen, MCP | 系统提示词、工具集、消息修剪 |
| AIOps 编排 | Plan-Execute-Replan 状态机 | `app/services/aiops_service.py` | LangGraph StateGraph | 新节点、条件边、输出格式 |
| Planner | 基于经验 + 工具列表生成计划 | `app/agent/aiops/planner.py` | retrieve_knowledge, MCP tools | 提示词、规划策略 |
| Executor | 执行单步，绑定工具 + ToolNode | `app/agent/aiops/executor.py` | ChatQwen, ToolNode | 并行执行、超时控制 |
| Replanner | 决策：继续/重规划/响应 | `app/agent/aiops/replanner.py` | ChatQwen | 决策阈值、强制终止条件 |
| MCP 客户端 | 多服务器连接 + 重试拦截 | `app/agent/mcp_client.py` | langchain-mcp-adapters | 拦截器链、服务发现 |
| 向量索引 | 文件分割→嵌入→入库 | `app/services/vector_index_service.py` | splitter, vector_store_manager | 批量索引、增量更新 |
| 文档分割 | Markdown 两阶段分割 + 合并 | `app/services/document_splitter_service.py` | langchain-text-splitters | 分割策略、最小分片阈值 |
| 向量存储 | Milvus VectorStore CRUD | `app/services/vector_store_manager.py` | langchain-milvus | 集合管理、检索参数 |
| 向量嵌入 | DashScope Embedding 标准接口 | `app/services/vector_embedding_service.py` | openai SDK (compat) | 模型/维度切换 |
| Milvus 管理 | 连接池 + Schema 自动创建 | `app/core/milvus_client.py` | pymilvus | 多集合、连接策略 |
| LLM 工厂 | OpenAI-compat 模式 LLM 创建 | `app/core/llm_factory.py` | langchain-openai | 多模型供应商切换 |
| MCP CLS | 日志查询工具服务 | `mcp_servers/cls_server.py` | fastmcp | 接入腾讯云 CLS SDK |
| MCP Monitor | 监控/工单查询工具服务 | `mcp_servers/monitor_server.py` | fastmcp | 接入 Prometheus/Grafana |
| Web 前端 | 纯静态 SPA (无框架) | `static/` | 无 | 可替换为 React/Vue |

---

## 5. 技术栈与选型权衡 / Tech Stack & Trade-offs

### 5.1 关键依赖 / Key Dependencies (from pyproject.toml)

| 依赖 | 版本范围 | 用途 |
|---|---|---|
| fastapi | ≥0.109 | Web 框架 + SSE |
| langgraph | ≥0.0.40 | Agent 状态图编排 |
| langchain / langchain-core | ≥0.1.0 | 工具/链/消息抽象 |
| langchain-mcp-adapters | ≥0.2.1 | MCP 协议接入 |
| langchain-qwq | ≥0.3.4 | ChatQwen 原生集成 |
| pymilvus | ≥2.3.5 | 向量数据库客户端 |
| dashscope | ≥1.14 | DashScope SDK |
| fastmcp | ≥2.14 | MCP 服务端框架 |
| pydantic-settings | ≥2.1 | 类型安全配置 |
| loguru | ≥0.7.2 | 结构化日志 |

### 5.2 架构风格判断

**模块化单体 + 工具微服务**
- 主服务是单进程 FastAPI（内含 RAG + AIOps 两条业务线）
- MCP Server 是轻量独立进程，可按需横向扩展
- Docker Compose 只承载基础设施（Milvus/etcd/MinIO）

### 5.3 选型权衡 / Design Trade-offs

```mermaid
quadrantChart
    title 选型权衡矩阵 / Trade-off Matrix
    x-axis "开发效率 Low" --> "High"
    y-axis "运行复杂度 Low" --> "High"
    quadrant-1 "慎用"
    quadrant-2 "理想"
    quadrant-3 "避免"
    quadrant-4 "当前选型"
    "模块化单体": [0.75, 0.3]
    "LangGraph 状态图": [0.6, 0.45]
    "MCP 工具化": [0.65, 0.5]
    "同步索引": [0.8, 0.2]
    "微服务化": [0.3, 0.8]
    "纯 ReAct Agent": [0.85, 0.6]
```

| # | 权衡 Trade-off | 当前选择 | 代价 |
|---|---|---|---|
| 1 | 模块化单体 vs 微服务 | 单体 | 扩展性受限，但部署简单 |
| 2 | LangGraph 状态图 vs 自由 ReAct | 状态图 | 设计成本高，但可控可观测 |
| 3 | MCP 工具协议 vs 直连 SDK | MCP | 多一跳网络延迟，但解耦彻底 |
| 4 | 同步索引 vs 异步队列 | 同步 | 大文件阻塞请求，但实现简单 |

---

## 6. 学习路径 / Learning Path

### 30 分钟速览 / 30-min Quick Tour

```mermaid
flowchart LR
    A["README.md<br/>目标与启动"] --> B["app/main.py<br/>系统入口"]
    B --> C["app/api/chat.py<br/>对话接口"]
    C --> D["app/api/aiops.py<br/>诊断接口"]
    D --> E["app/api/file.py<br/>上传接口"]
```

目标：理解项目做什么、怎么跑、有哪些 API。

### 2 小时深入 / 2-hour Deep Dive

| 顺序 | 文件 | 关注点 |
|---|---|---|
| 1 | `app/services/rag_agent_service.py` | Agent 如何初始化工具、如何流式输出 |
| 2 | `app/services/aiops_service.py` | StateGraph 的构建与条件边 |
| 3 | `app/agent/aiops/planner.py` | 经验检索 + 工具描述 → 结构化计划 |
| 4 | `app/agent/aiops/executor.py` | ToolNode 自动工具调用 |
| 5 | `app/agent/mcp_client.py` | 单例 + 重试拦截器模式 |
| 6 | `app/services/vector_index_service.py` | 分割→嵌入→入库全链路 |

### 1 天掌握 / 1-day Mastery

1. 从一次真实请求走读日志（chat/aiops/upload 各跑一次，看 `logs/app_*.log`）
2. 追踪配置流：`.env` → `app/config.py` → 各模块使用点
3. 动手实验：在 `mcp_servers/monitor_server.py` 添加一个新工具，观察 Planner 如何自动发现
4. 阅读 `app/services/document_splitter_service.py` 理解分割策略
5. 尝试修改 Replanner 的 `MAX_STEPS` 观察行为变化
6. 补充一个集成测试：模拟上传→检索→验证结果

---

## 7. 风险与技术债 / Risks & Tech Debt

| 优先级 | 问题 | 影响 | 建议 |
|---|---|---|---|
| 🔴 高 | 同步索引阻塞上传接口 | 大文件/并发场景超时 | 引入任务队列（Celery/ARQ） |
| 🔴 高 | 无测试目录，自动化回归缺失 | 重构风险高 | 补充 pytest 集成测试 |
| 🟡 中 | MCP 默认配置 vs 文档示例不一致 | CLS 端口：代码 3000 vs 文档 8003 | 统一到 config.py |
| 🟡 中 | 全局单例初始化时机耦合 | vector_store_manager 模块加载即连接 | 延迟初始化或依赖注入 |
| 🟡 中 | Replanner 决策依赖 LLM 输出格式 | 解析失败导致死循环 | 增加 fallback + 超时熔断 |
| 🟢 低 | CORS 配置 allow_origins=["*"] | 安全风险（生产环境） | 收敛到具体域名 |
| 🟢 低 | 日志仅本地文件输出 | 多实例场景不便查询 | 接入集中式日志系统 |

---

## 8. 下一步建议 / Next Steps

### 推荐阅读顺序（带目的）

| # | 文件 | 你将理解 |
|---|---|---|
| 1 | `app/main.py` | 系统如何启动和组装 |
| 2 | `app/config.py` | 所有可调参数在哪 |
| 3 | `app/api/chat.py` | 请求如何进入系统 |
| 4 | `app/services/rag_agent_service.py` | Agent 完整生命周期 |
| 5 | `app/api/aiops.py` | SSE 流式返回协议 |
| 6 | `app/services/aiops_service.py` | LangGraph 状态图实战 |
| 7 | `app/agent/aiops/planner.py` | 经验驱动的规划设计 |
| 8 | `app/agent/aiops/executor.py` | ToolNode 自动执行 |
| 9 | `app/agent/aiops/replanner.py` | 决策逻辑与强制终止 |
| 10 | `app/api/file.py` | 上传链路入口 |
| 11 | `app/services/vector_index_service.py` | 索引全流程 |
| 12 | `app/services/document_splitter_service.py` | 智能分割策略 |
| 13 | `app/services/vector_store_manager.py` | Milvus 操作封装 |
| 14 | `app/agent/mcp_client.py` | MCP 连接与重试 |
| 15 | `mcp_servers/cls_server.py` | 工具实现示例 |
| 16 | `mcp_servers/monitor_server.py` | 监控工具实现 |

### 想加功能？从这里入手

| 场景 | 入手点 |
|---|---|
| 新增一种诊断工具 | `mcp_servers/` 添加工具函数，Agent 自动发现 |
| 支持新文档格式（PDF） | `document_splitter_service.py` 扩展 `split_document()` |
| 切换 LLM 供应商 | `app/core/llm_factory.py` 修改 `base_url` |
| 增加对话历史持久化 | `rag_agent_service.py` 替换 `MemorySaver` 为 DB-backed checkpointer |
| 增加 AIOps 诊断节点 | `aiops_service.py` 在 `_build_graph()` 中添加节点和边 |

---

## 附录: 完整模块依赖图 / Appendix: Full Module Dependency Graph

```mermaid
graph TD
    MAIN["app/main.py"] --> API_CHAT["app/api/chat.py"]
    MAIN --> API_AIOPS["app/api/aiops.py"]
    MAIN --> API_FILE["app/api/file.py"]
    MAIN --> API_HEALTH["app/api/health.py"]
    MAIN --> CONFIG["app/config.py"]
    MAIN --> MILVUS_MGR["app/core/milvus_client.py"]

    API_CHAT --> RAG_SVC["app/services/rag_agent_service.py"]
    API_AIOPS --> AIOPS_SVC["app/services/aiops_service.py"]
    API_FILE --> IDX_SVC["app/services/vector_index_service.py"]

    RAG_SVC --> MCP_CLIENT["app/agent/mcp_client.py"]
    RAG_SVC --> TOOLS["app/tools/*"]
    RAG_SVC --> CONFIG

    AIOPS_SVC --> PLANNER["app/agent/aiops/planner.py"]
    AIOPS_SVC --> EXECUTOR["app/agent/aiops/executor.py"]
    AIOPS_SVC --> REPLANNER["app/agent/aiops/replanner.py"]

    PLANNER --> MCP_CLIENT
    PLANNER --> TOOLS
    EXECUTOR --> MCP_CLIENT
    EXECUTOR --> TOOLS

    IDX_SVC --> SPLITTER["app/services/document_splitter_service.py"]
    IDX_SVC --> VS_MGR["app/services/vector_store_manager.py"]

    VS_MGR --> EMBEDDING["app/services/vector_embedding_service.py"]
    VS_MGR --> MILVUS_MGR

    TOOLS --> VS_MGR

    MCP_CLIENT --> CONFIG

    classDef api fill:#e1f5fe
    classDef service fill:#fff3e0
    classDef agent fill:#f3e5f5
    classDef core fill:#e8f5e9

    class API_CHAT,API_AIOPS,API_FILE,API_HEALTH api
    class RAG_SVC,AIOPS_SVC,IDX_SVC,SPLITTER,VS_MGR,EMBEDDING service
    class PLANNER,EXECUTOR,REPLANNER,MCP_CLIENT,TOOLS agent
    class MAIN,CONFIG,MILVUS_MGR core
```

图例 / Legend:
- 🔵 蓝色 = API 层
- 🟠 橙色 = Service 层
- 🟣 紫色 = Agent 层
- 🟢 绿色 = Core 层
