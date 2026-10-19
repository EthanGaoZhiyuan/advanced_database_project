# BoA 手动演示操作指南

适用环境：当前项目的 `boa-tutorial` Docker 环境和新版 SQL。

本指南通过 CloudBeaver 完成三个源数据库、数据仓库和 ETL 的手动演示。文中的 SQL 文件路径均相对于项目的 `workspace/sql/`；终端命令在项目根目录执行。

如果服务还没有启动，先在终端执行：

```bash
docker compose up -d --build
docker compose ps
```

打开 [CloudBeaver](http://localhost:8978)。在 Ubuntu 虚拟机中启动 Docker 时，也在该虚拟机的浏览器中打开这个地址。

## 1. 怎样执行一个 SQL 文件

1. 用文本编辑器打开项目中的 `.sql` 文件。
2. 在 CloudBeaver 中打开连接到目标数据库的 SQL 编辑器。
3. 用文件的**完整内容替换编辑器中的旧 SQL**，清除文字选区。
4. 点击 **Execute SQL script（执行脚本）**，执行文件中的全部语句。
5. 确认没有报错，再执行下一个文件。

不要只输入文件名，也不要只执行光标所在的一条语句。文件中的 `DO $$ ... $$` 必须保持完整。参考 [CloudBeaver SQL 编辑器说明](https://dbeaver.com/docs/cloudbeaver/SQL-Editor/)。

**左侧树选中某个数据库，不代表当前 SQL 编辑器已经切换过去。** 检查顶部的数据库选择，例如 `public@boa_loans`，并在执行每个源系统脚本前单独运行：

```sql
SELECT current_database();
```

以查询返回的数据库名为准。三套源系统使用相同的表名，但字段不同，必须分别在各自的数据库中执行。

## 2. 连接仓库，创建三个源数据库

当前 Docker 环境的 PostgreSQL 连接配置：

| 配置项 | 值 |
|---|---|
| Host | `postgres` |
| Port | `5432` |
| Database | `boa` |
| Username | `student` |
| Password | `student` |

这是 CloudBeaver 容器访问 PostgreSQL 的地址。CloudBeaver 的网页登录账号与 PostgreSQL 数据库账号是两套账号。

`boa` 已由 Docker 初始化。先查询已有数据库：

```sql
SELECT datname
FROM pg_database
WHERE datname IN ('boa', 'boa_savings', 'boa_cards', 'boa_loans')
ORDER BY datname;
```

只创建缺少的源数据库。以下语句在 **Auto-commit 模式下逐条执行**，不要放进 `BEGIN`：

```sql
CREATE DATABASE boa_savings;
```

```sql
CREATE DATABASE boa_cards;
```

```sql
CREATE DATABASE boa_loans;
```

PostgreSQL 的 `CREATE DATABASE` 不支持 `IF NOT EXISTS`，也不能在事务中执行。参考 [PostgreSQL CREATE DATABASE 文档](https://www.postgresql.org/docs/15/sql-createdatabase.html)。

可以为四个数据库分别建立并命名连接，其他参数保持相同，仅修改 Database；也可以使用一个显示所有数据库的连接，通过编辑器顶部切换数据库。每次切换后都用 `SELECT current_database();` 确认。

如果数据库已经创建却没有显示在左侧，检查连接中的 **Show all databases** 设置，然后刷新或重新连接。

## 3. 创建源系统的表

按下面的数据库与文件对应关系执行完整脚本：

| 顺序 | 编辑器连接的数据库 | 执行文件 |
|---|---|---|
| 1 | `boa_savings` | `sources/savings.sql` |
| 2 | `boa_cards` | `sources/cards.sql` |
| 3 | `boa_loans` | `sources/loans.sql` |

如果此前删除了某个源数据库的 `public`，先在那个数据库执行：

```sql
CREATE SCHEMA IF NOT EXISTS public;
```

完成每个源数据库的建表后，在同一个编辑器执行检查：

```sql
SELECT
    current_database() AS database_name,
    to_regclass('public.customers') AS customers_table,
    to_regclass('public.accounts') AS accounts_table,
    to_regclass('public.daily_balances') AS balances_table,
    to_regclass('public.transactions') AS transactions_table;
```

数据库名应与当前业务一致，四个表的结果都应有值。`NULL` 表示没有找到对应的表；此时先完成建表，不要继续导入数据。

三套系统的交易表结构有所不同：

| 数据库 | 交易编号字段 | 交易日期字段 |
|---|---|---|
| `boa_savings` | `txn_id` | `txn_timestamp` |
| `boa_cards` | `auth_id` | `posted_date` |
| `boa_loans` | `event_id` | `event_date` |

`CREATE TABLE IF NOT EXISTS` 只会跳过已存在的表，不会修改旧表字段。如果报日期字段不存在，先核对当前数据库和实际表结构。之前用于保留旧表的 `ALTER SCHEMA ... RENAME ...` 是一次性修复操作，不属于正常演示流程。

## 4. 创建仓库结构

打开连接 **`boa`** 的编辑器，确认数据库后执行：

```sql
SELECT current_database();
SELECT set_config('boa.source_user', session_user, false);
SET boa.source_password = 'student';
```

这里的密码适用于当前 Docker 默认环境。当前 `001_schema.sql` 中也包含 `student` 密码设置；如果实际 PostgreSQL 密码不同，需要同步修改执行内容中的该设置，避免覆盖前面填写的密码。

然后在**同一个编辑器**中依次执行这些文件的完整内容：

| 顺序 | 执行文件 | 作用 |
|---|---|---|
| 1 | `001_schema.sql` | 配置三个源数据库的外部表，创建仓库 schema、表和约束 |
| 2 | `002_reports.sql` | 创建 Gold 报表视图 |
| 3 | `003_integrity.sql` | 创建数据完整性检查函数和触发器 |
| 4 | `004_input_contract.sql` | 创建日期、金额、交易转换及输入检查函数 |

完成后刷新数据库列表，可以看到 `boa_src_savings`、`boa_src_cards`、`boa_src_loans`、`boa_bronze`、`boa_silver`、`boa_vault`、`boa_gold` 和 `boa_audit` 等 schema。

`002_reports.sql` 此时只是创建报表视图，还没有分析结果。若源表是在此前运行 `001_schema.sql` 之后才修正的，需要重新完整执行 `001_schema.sql`，刷新外部表定义。

## 5. 导入测试数据

| 顺序 | 编辑器连接的数据库 | 执行文件 |
|---|---|---|
| 1 | `boa_savings` | `seed/savings.sql` |
| 2 | `boa_cards` | `seed/cards.sql` |
| 3 | `boa_loans` | `seed/loans.sql` |
| 4 | `boa` | `seed/registry.sql` |

这些文件已经包含自己的 `BEGIN` 和 `COMMIT`，直接执行完整内容，不要再包一层事务。测试数据文件较大，等待执行完成后再继续。

前三份加载业务数据，最后一份加载客户跨系统映射和批次信息。`sources/loans.sql` 是建表文件，`seed/loans.sql` 是数据文件，其他两个业务同理。

**从 `seed/registry.sql` 开始，后续仓库操作都使用同一个 `boa` 编辑器，不要断开连接或切换到其他数据库。** 批次信息会保存在当前数据库会话中。

导入 registry 后确认批次变量已经设置：

```sql
SELECT current_database(), current_setting('boa.batch_id');
```

## 6. 准备本次 ETL 的运行记录

在同一个 `boa` 编辑器执行：

```sql
-- 新建本次运行编号
SELECT set_config('boa.run_id', gen_random_uuid()::text, false);

-- 从刚导入的批次信息中取得处理日期
SELECT set_config(
    'boa.dates',
    (
        SELECT array_agg(d.value::date ORDER BY d.value::date)::text
        FROM boa_audit.batch_manifest b
        CROSS JOIN LATERAL
            jsonb_array_elements_text(b.manifest->'dates') AS d(value)
        WHERE b.batch_id = current_setting('boa.batch_id')
    ),
    false
);

-- 修正样例文件目录记录
UPDATE boa_audit.batch_manifest
SET input_directory = '/workspace/data'
WHERE batch_id = current_setting('boa.batch_id');

-- 记录本次 ETL 开始
INSERT INTO boa_audit.pipeline_run
    (run_id, batch_id, status, current_stage)
VALUES (
    current_setting('boa.run_id')::uuid,
    current_setting('boa.batch_id'),
    'RUNNING',
    'ingest-bronze'
);
```

这部分平时由 Python 完成，手动演示时需要自己执行。此时保持 Auto-commit，让开始记录先保存，再进入下一步的 ETL 事务。

## 7. 依次执行 ETL

先执行：

```sql
BEGIN;
SELECT pg_advisory_xact_lock(32113001);
```

现有 `000_manual.sql` 已包含第 6 步的运行准备和上面的事务开始代码。如果已在第 5 步后完整执行该文件，就直接从下面的 `extract_bronze.sql` 开始，不要重复创建运行记录或再次执行 `BEGIN`。

在同一个 `boa` 编辑器中，按顺序执行以下文件的完整内容：

| 顺序 | 文件 | 展示的功能 |
|---|---|---|
| 1 | `extract_bronze.sql` | 从三个源数据库抽取原始数据，记录来源和批次 |
| 2 | `build_silver.sql` | 清洗字段、统一客户、整合账户及交易 |
| 3 | `load_vault.sql` | 写入 Hub、Link、Satellite，保存历史 |
| 4 | `build_gold.sql` | 加载维度表和事实表 |
| 5 | `finish_run.sql` | 检查发布完整性，标记运行成功 |

**中间不要提交事务，不要切换编辑器或连接，也不要同时运行 Python ETL。** 文件里的临时表需要在同一个事务中继续使用。

全部成功后执行：

```sql
COMMIT;
```

这个手动流程将整个 ETL 放在一个事务里；Python 流程则按层分别提交。`finish_run.sql` 本身不会执行 `COMMIT`。

### 某一步报错后的处理

立即停止执行后续文件。在发生错误的同一个编辑器中，先**单独执行**：

```sql
ROLLBACK;
```

然后记录失败：

```sql
UPDATE boa_audit.pipeline_run
SET status = 'FAILED',
    finished_at = clock_timestamp(),
    error_message = 'Manual ETL failed'
WHERE run_id = current_setting('boa.run_id')::uuid
  AND status = 'RUNNING';
```

解决第一条错误后，从第 6 步创建新的运行记录，再从 Bronze 开始执行第 7 步。事务回滚后临时表也会消失，不能从中间某个文件直接继续。

## 8. 查询结果，完成业务演示

先检查本次运行是否成功：

```sql
SELECT run_id, status, records_read, records_written
FROM boa_audit.pipeline_run
ORDER BY started_at DESC;
```

本次运行应为 `SUCCEEDED`。再展示三类业务分析：

```sql
-- ① 同一个客户在储蓄、信用卡、贷款业务中的统一视图
SELECT *
FROM boa_gold.v_customer_360
WHERE enterprise_customer_id = 'EC000001'
  AND business_date = DATE '2026-03-31';

-- ② 客户持有的产品组合
SELECT *
FROM boa_gold.v_product_combinations
WHERE business_date = DATE '2026-03-31'
ORDER BY customer_count DESC;

-- ③ 每日信用卡和贷款负债趋势
SELECT *
FROM boa_gold.v_borrowing_daily
ORDER BY business_date;
```

这些报表只展示已成功发布的数据，因此必须完成 `finish_run.sql` 和最终的 `COMMIT`。

## 9. 校验 ETL 结果

第 7 步已经完成 `finish_run.sql` 和 `COMMIT`，第 8 步能查到成功发布的数据后，再继续下面的操作。

**本指南后续所有 `bash` 命令都在 Ubuntu 的项目根目录终端执行，不在 CloudBeaver 或 Neo4j 的查询编辑器中执行。** 命令会自动进入 Python 容器运行脚本，不需要先执行 `docker compose exec python bash`。

运行独立仓库校验：

```bash
docker compose exec python python boa_etl/07_validate_warehouse.py
```

脚本检查客户身份、账户关联、余额、交易和数据来源，并与独立的预期结果比较。终端最后应显示：

```text
Warehouse validation: PASSED; details in /workspace/output
```

在宿主机项目的 `workspace/output/` 中查看：

| 文件 | 内容 |
|---|---|
| `validation.txt` | 便于阅读的检查结果 |
| `validation.json` | 详细校验结果 |
| `explain_analyze.json` | 查询执行计划和本次测得的耗时 |

如果结果为 `FAILED`，先查看失败项并修正，再继续展示。SQL 成功执行和独立数据校验通过需要分别确认。

## 10. 导出分析报表

校验通过后执行：

```bash
docker compose exec python python boa_etl/08_run_analytics.py
```

终端会输出各报表的行数和前五条记录。完整结果保存在宿主机项目的 `workspace/output/`：

| 文件 | 分析内容 |
|---|---|
| `customer_360.csv` | 客户统一资料、持有产品和余额 |
| `product_combinations.csv` | 客户持有的产品组合 |
| `borrowing_daily.csv` | 每日信用卡和贷款负债 |
| `transaction_types.csv` | 交易类型统计 |
| `top_merchants.csv` | 商户消费统计 |
| `analytics.json` | 本次分析日期和各报表行数 |

这一步用于导出分析结果。Dashboard 会直接查询数据库，不依赖这些 CSV 才能显示。

## 11. 构建并校验 Graph Model

在项目根目录终端执行：

```bash
docker compose exec python python boa_etl/09_build_graph.py
```

脚本读取最新发布的 Gold 数据，写入 Neo4j，然后核对节点、关系及属性。终端应显示导出的业务日期、节点数量，以及：

```text
Graph validation: PASSED
```

宿主机项目的 `workspace/output/` 中会生成 `graph_export.json` 和 `graph_validation.json`。

现有 Graph 包含五类节点：`Customer`、`Account`、`Product`、`Address`、`Merchant`。主要关系是：

```text
Customer ──HOLDS──────────→ Account
Account  ──OF_PRODUCT─────→ Product
Customer ──LIVES_AT───────→ Address
Account  ──TRANSACTED_AT──→ Merchant
```

每次重新发布 Gold 后，需要重新运行这一步，才能让 Neo4j 与新的仓库发布结果一致。

## 12. 在 Neo4j Browser 查看图模型和实际关系

### 12.1 打开并登录

在 Ubuntu 浏览器打开 [Neo4j Browser](http://localhost:7474/browser/)，填写：

| 配置项 | 值 |
|---|---|
| Connect URL | `bolt://localhost:7687` |
| Username | `neo4j` |
| Password | `password` |
| Database | `neo4j` |

本项目在 Neo4j Browser 中查询实际图数据。CloudBeaver 的 PostgreSQL 编辑器用于关系数据库 SQL；表的 ERD 和 Neo4j 的节点关系图是不同的展示内容。

### 12.2 查看整体模型结构

在 Neo4j Browser 顶部查询框执行：

```cypher
CALL db.schema.visualization();
```

在结果区域选择 **Graph**，查看节点类型和关系类型的结构概览。这个结果基于数据库元数据；实际客户关系用下一步的查询展示。参考 [Neo4j Browser 官方说明](https://neo4j.com/docs/browser/legacy/visual-tour/)。

### 12.3 查看具体客户的账户和产品

在 Neo4j Browser 中分别执行下面两个参数命令：

```text
:param namespace => 'boa'
```

```text
:param enterprise_customer_id => 'EC000001'
```

然后执行：

```cypher
MATCH path=(c:Customer {
  namespace:$namespace,
  enterprise_customer_id:$enterprise_customer_id,
  boa_managed:true
})
  -[:HOLDS {namespace:$namespace,boa_managed:true}]->
  (:Account {namespace:$namespace,boa_managed:true})
  -[:OF_PRODUCT {namespace:$namespace,boa_managed:true}]->
  (:Product {namespace:$namespace,boa_managed:true})
RETURN path LIMIT 30;
```

切换到 **Graph** 结果视图，即可看到该客户、其账户及产品类型。点击节点或关系可查看属性，拖动节点可以调整布局。

### 12.4 查看共同地址和共同商户

打开项目的 `workspace/graph/browser.cypher`，在刚才设置参数的 Neo4j Browser 中，分别复制执行其中后两段完整查询：

| 查询 | 演示内容 |
|---|---|
| Shared address | 通过同一个地址连接的不同客户 |
| Shared card merchants | 通过信用卡消费商户连接的不同客户 |

一次执行一段 `MATCH ... RETURN ...;`，并选择 **Graph** 结果视图。需要换客户时，重新执行 `:param enterprise_customer_id => '客户编号'`，再运行查询。

共同地址和共同商户只表示关联线索，不会据此合并客户身份，也不能据此确认客户之间存在私人关系。

## 13. 启动和演示 Dashboard

### 13.1 启动页面

在 Ubuntu 项目根目录终端执行：

```bash
docker compose exec python streamlit run dashboard/app.py --server.address=0.0.0.0 --server.port=8501 --browser.gatherUsageStats=false
```

保持这个终端运行，在 Ubuntu 浏览器打开 [Dashboard](http://localhost:8501)。需要执行其他终端命令时，另开一个终端；按 `Ctrl+C` 会停止 Dashboard。

### 13.2 按业务场景展示

先在左侧 **Published business date** 选择最新发布日期。当前样例完整运行后，最新日期应为 `2026-03-31`。

| 页面 | 建议操作 | 展示的业务能力 |
|---|---|---|
| Customer 360 | 选择 `EC000001`，查看统一资料、账户列表及余额趋势 | 把同一客户在三个业务中的信息整合在一起 |
| Product Holdings | 查看产品持有比例、产品组合和跨产品持有情况 | 分析客户使用了哪些产品及产品之间的重叠 |
| Borrowing Balances | 查看信用卡欠款、贷款本金和每日趋势 | 汇总客户及全行负债，储蓄不计入负债 |
| Transaction Activity | 选择客户，查看交易明细、类型及商户消费 | 分析客户的交易活动和消费情况 |
| Relationships | 选择客户，查看关系图并切换关联分析 | 从 Neo4j 查询账户、地址和商户关系 |

可以使用页面中的 CSV 下载按钮导出当前分析结果。

前四个页面读取 PostgreSQL Gold；`Relationships` 读取 Neo4j。Graph 默认导出最新发布日期，演示时让 Dashboard 的选择日期与 Graph 日期保持一致。

如果重新执行过 ETL，先确认校验通过，再运行 `09_build_graph.py` 更新 Graph，最后点击 Dashboard 左侧的 **Refresh from database**。

### 13.3 演示时使用哪个页面

| 地址 | 用途 |
|---|---|
| [CloudBeaver](http://localhost:8978) | 查看源表和仓库各层，执行 SQL，展示 ETL 和报表查询 |
| [Neo4j Browser](http://localhost:7474/browser/) | 执行 Cypher，查看 Graph Model 结构和具体节点关系 |
| [Dashboard](http://localhost:8501) | 展示业务分析图表和客户关系分析 |

演示结束后，在运行 Streamlit 的终端按 `Ctrl+C`。如果也需要停止 Docker 服务，在项目根目录执行 `docker compose down`，保留数据库数据卷供下次使用。

## 常见问题速查

| 现象 | 检查与处理 |
|---|---|
| 左侧选中了源库，查询仍返回 `boa` | 切换 SQL 编辑器顶部的活动数据库，再执行 `SELECT current_database();` |
| 四个 `to_regclass` 结果都是 `NULL` | 当前库缺少源表，执行对应 `sources/*.sql` 的完整内容 |
| `posted_date` 或 `event_date` 不存在 | 核对当前库和已有 `transactions` 的字段；重复运行 `CREATE TABLE IF NOT EXISTS` 不会修正旧结构 |
| `current transaction is aborted` | 在原编辑器单独执行 `ROLLBACK;`，处理此前第一条错误后再重试 |
| 找不到 `boa.batch_id`、`boa.run_id` 或 `boa.dates` | 检查是否换了数据库会话、遗漏 registry 导入或运行准备步骤 |
| Gold 表有数据，报表没有结果 | 检查本次运行是否已完成 `finish_run.sql`、状态为 `SUCCEEDED`，并已 `COMMIT` |
| Neo4j Browser 无法打开或连接 | 在项目根目录执行 `docker compose ps`，检查 `neo4j` 服务；在运行 Docker 的 Ubuntu 浏览器中访问 `7474`，连接地址使用 `bolt://localhost:7687` |
| Graph 查询没有节点或关系 | 确认 `09_build_graph.py` 执行成功、选择的是 `neo4j` 数据库，且客户编号存在；查询使用 `browser.cypher` 时先设置两个参数 |
| Dashboard 提示没有发布数据 | 确认手动 ETL 已提交且运行状态为 `SUCCEEDED`，然后刷新页面 |
| Relationships 提示没有 Graph 或数据已过期 | 运行 `09_build_graph.py` 后刷新，核对 Graph 业务日期与 Dashboard 选择日期 |
| Dashboard 的 `8501` 地址无法打开 | Docker 启动后还需要单独运行第 13 步的 Streamlit 命令，并保持该终端运行 |
