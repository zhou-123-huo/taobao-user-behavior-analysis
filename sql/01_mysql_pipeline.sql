-- ============================================================================
-- 淘宝用户行为分析 · MySQL 8.0 完整脚本（五阶段）
--
-- 数据：UserBehavior_sample.csv（1,000,000 行）
-- 实况：有表头行；behavior_type 是文本 pv/fav/cart/buy（不是数字）
--       timestamp 为秒级整数，含负数与超大值 → 必须 SIGNED，且需过滤脏数据
--       无金额字段 → RFM 的 M 只能用「购买商品件数」替代
--
-- ⚠️ 字段名适配：
--      脚本中时间戳列统一写为 `timestamp`（反引号包裹，MySQL 保留字必须加反引号）
--      若你的表该列叫 ts / time_stamp，请先全局替换后再执行
--      不确定时先跑第 0 步 DESC 确认
-- ============================================================================

SET time_zone = '+8:00';             -- 关键：保证 FROM_UNIXTIME 按北京时间转换
USE taobao;                          -- ← 改成你的数据库名


-- ############################################################################
-- 第 0 步：确认当前表结构（已导入的话先看这个）
-- ############################################################################
DESC user_behavior;
SELECT COUNT(*) AS total_rows FROM user_behavior;


-- ############################################################################
-- 阶段 ① 入库（若已导入可跳过，保留备查）
-- ############################################################################

DROP TABLE IF EXISTS user_behavior;
CREATE TABLE user_behavior (
    id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id       INT          NOT NULL,
    item_id       INT          NOT NULL,
    category_id   INT          NOT NULL,
    behavior_type VARCHAR(10)  NOT NULL,   -- pv / fav / cart / buy（文本）
    `timestamp`   INT          NOT NULL    -- 秒级时间戳，SIGNED 才能存负数脏数据
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Navicat 图形化导入：右键表 → 导入向导 → CSV → 勾选「第一行含列名」→ 追加记录
-- 命令行导入（连接时需带 --local-infile=1，并先 SET GLOBAL local_infile=1）：
LOAD DATA LOCAL INFILE 'D:/PycharmProjects/PythonProject2/data/UserBehavior_sample.csv'
INTO TABLE user_behavior
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(user_id, item_id, category_id, behavior_type, `timestamp`);

SELECT COUNT(*) AS loaded_rows FROM user_behavior;   -- 验收：应为 1000000


-- ############################################################################
-- 阶段 ② 清洗（去重 + 时间解析 + 剔除脏数据）
--      官方时间区间：北京时间 2017-11-25 00:00:00 ~ 2017-12-03 23:59:59
--      对应秒级时间戳：1511539200 ~ 1512316799
-- ############################################################################

-- 2.1 清洗前后对照：把每个环节剔除的行数记录下来（写简历/报告要用）
SELECT
    COUNT(*)                                                              AS raw_rows,
    COUNT(DISTINCT CONCAT(user_id,'-',item_id,'-',`timestamp`))           AS after_distinct,
    SUM(`timestamp` BETWEEN 1511539200 AND 1512316799)                    AS valid_ts_rows,
    COUNT(*) - SUM(`timestamp` BETWEEN 1511539200 AND 1512316799)         AS dirty_ts_rows,
    ROUND((COUNT(*) - SUM(`timestamp` BETWEEN 1511539200 AND 1512316799))
          / COUNT(*) * 100, 2)                                            AS dirty_pct
FROM user_behavior;

-- 2.2 去重后剩余行数
SELECT COUNT(*) AS dedup_rows
FROM (
    SELECT DISTINCT user_id, item_id, category_id, behavior_type, `timestamp`
    FROM user_behavior
) d;

-- 2.3 生成干净表（一步完成 去重 + 时间解析 + 剔除脏数据）
--     比「ALTER 加列 → UPDATE 全表」快得多
DROP TABLE IF EXISTS ub_clean;
CREATE TABLE ub_clean AS
SELECT
    user_id,
    item_id,
    category_id,
    behavior_type,
    `timestamp`                        AS ts,
    FROM_UNIXTIME(`timestamp`)         AS dt,
    DATE(FROM_UNIXTIME(`timestamp`))   AS d_date,
    HOUR(FROM_UNIXTIME(`timestamp`))   AS d_hour
FROM (
    SELECT DISTINCT user_id, item_id, category_id, behavior_type, `timestamp`
    FROM user_behavior
) d
WHERE `timestamp` BETWEEN 1511539200 AND 1512316799;

ALTER TABLE ub_clean ADD INDEX idx_date (d_date),
                     ADD INDEX idx_user (user_id),
                     ADD INDEX idx_behavior (behavior_type),
                     ADD INDEX idx_hour (d_hour);

-- 2.4 验收：日期应严格落在 2017-11-25 ~ 2017-12-03
SELECT COUNT(*) AS clean_rows FROM ub_clean;
SELECT MIN(d_date) AS min_date, MAX(d_date) AS max_date, COUNT(DISTINCT d_date) AS days
FROM ub_clean;
SELECT behavior_type, COUNT(*) AS cnt, ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM ub_clean GROUP BY behavior_type ORDER BY cnt DESC;


-- ############################################################################
-- 阶段 ③ 指标计算（简历核心弹药，全部 SQL 产出）
-- ############################################################################

-- 3.1 流量总览：PV / UV / 人均浏览量
SELECT
    SUM(behavior_type = 'pv')            AS total_pv,
    COUNT(DISTINCT user_id)              AS total_uv,
    ROUND(SUM(behavior_type = 'pv') / COUNT(DISTINCT user_id), 2) AS pv_per_user,
    SUM(behavior_type = 'buy')           AS total_buy,
    COUNT(DISTINCT item_id)              AS item_cnt,
    COUNT(DISTINCT category_id)          AS category_cnt
FROM ub_clean;

-- 3.2 转化漏斗 · 行为数口径
SELECT
    SUM(behavior_type = 'pv')                                                  AS pv_cnt,
    SUM(behavior_type = 'cart')                                                AS cart_cnt,
    SUM(behavior_type = 'fav')                                                 AS fav_cnt,
    SUM(behavior_type = 'buy')                                                 AS buy_cnt,
    ROUND(SUM(behavior_type = 'cart') / SUM(behavior_type = 'pv') * 100, 2)    AS pv_to_cart,
    ROUND(SUM(behavior_type = 'buy')  / SUM(behavior_type = 'cart') * 100, 2)  AS cart_to_buy,
    ROUND(SUM(behavior_type = 'buy')  / SUM(behavior_type = 'pv') * 100, 2)    AS pv_to_buy
FROM ub_clean;

-- 3.3 转化漏斗 · 用户数口径（更专业，面试优先讲这个）
WITH user_flag AS (
    SELECT
        user_id,
        MAX(behavior_type = 'pv')   AS has_pv,
        MAX(behavior_type = 'cart') AS has_cart,
        MAX(behavior_type = 'fav')  AS has_fav,
        MAX(behavior_type = 'buy')  AS has_buy
    FROM ub_clean
    GROUP BY user_id
)
SELECT
    COUNT(*)                                        AS uv_total,
    SUM(has_cart)                                   AS uv_cart,
    SUM(has_fav)                                    AS uv_fav,
    SUM(has_buy)                                    AS uv_buy,
    ROUND(SUM(has_cart) / COUNT(*) * 100, 2)        AS cart_rate,
    ROUND(SUM(has_buy)  / COUNT(*) * 100, 2)        AS buy_rate,
    ROUND(SUM(has_buy)  / SUM(has_cart) * 100, 2)   AS cart_to_buy_rate
FROM user_flag;

-- 3.4 时段分析：24 小时活跃分布
SELECT
    d_hour,
    COUNT(*)                        AS cnt,
    SUM(behavior_type = 'pv')       AS pv_cnt,
    SUM(behavior_type = 'cart')     AS cart_cnt,
    SUM(behavior_type = 'buy')      AS buy_cnt,
    COUNT(DISTINCT user_id)         AS uv
FROM ub_clean
GROUP BY d_hour
ORDER BY d_hour;

-- 3.5 日趋势
SELECT
    d_date,
    COUNT(*)                    AS cnt,
    COUNT(DISTINCT user_id)     AS uv,
    SUM(behavior_type = 'pv')   AS pv_cnt,
    SUM(behavior_type = 'buy')  AS buy_cnt,
    ROUND(SUM(behavior_type = 'buy') / SUM(behavior_type = 'pv') * 100, 2) AS buy_rate
FROM ub_clean
GROUP BY d_date
ORDER BY d_date;

-- 3.6 留存：按用户首次活跃日分组，算次日 / 3 日 / 7 日留存
--     注意：数据只有 9 天，7 日留存只有最早几批用户能算出来
WITH first_day AS (
    SELECT user_id, MIN(d_date) AS f_date
    FROM ub_clean
    GROUP BY user_id
),
user_date AS (
    SELECT DISTINCT user_id, d_date
    FROM ub_clean
)
SELECT
    f.f_date,
    COUNT(DISTINCT f.user_id) AS new_users,
    ROUND(COUNT(DISTINCT CASE WHEN ud.d_date = DATE_ADD(f.f_date, INTERVAL 1 DAY) THEN ud.user_id END)
          / COUNT(DISTINCT f.user_id) * 100, 2) AS ret_1d,
    ROUND(COUNT(DISTINCT CASE WHEN ud.d_date = DATE_ADD(f.f_date, INTERVAL 3 DAY) THEN ud.user_id END)
          / COUNT(DISTINCT f.user_id) * 100, 2) AS ret_3d,
    ROUND(COUNT(DISTINCT CASE WHEN ud.d_date = DATE_ADD(f.f_date, INTERVAL 7 DAY) THEN ud.user_id END)
          / COUNT(DISTINCT f.user_id) * 100, 2) AS ret_7d
FROM first_day f
LEFT JOIN user_date ud ON ud.user_id = f.user_id
GROUP BY f.f_date
ORDER BY f.f_date;

-- 3.7 RFM（⚠️ 数据集无金额字段，M 用「购买商品件数」替代，务必在报告中说明）
DROP TABLE IF EXISTS rfm;
CREATE TABLE rfm AS
WITH buy_agg AS (
    SELECT
        user_id,
        MAX(d_date)               AS last_buy_date,
        COUNT(*)                  AS buy_cnt,
        COUNT(DISTINCT item_id)   AS buy_items
    FROM ub_clean
    WHERE behavior_type = 'buy'
    GROUP BY user_id
),
ref AS (
    SELECT MAX(d_date) AS ref_date FROM ub_clean
)
SELECT
    b.user_id,
    DATEDIFF(r.ref_date, b.last_buy_date) AS r_days,
    b.buy_cnt                             AS f_cnt,
    b.buy_items                           AS m_items
FROM buy_agg b
CROSS JOIN ref r;

-- RFM 五分位打分与分群
WITH scored AS (
    SELECT
        user_id, r_days, f_cnt, m_items,
        NTILE(5) OVER (ORDER BY r_days  DESC) AS r_score,   -- R 越小越好
        NTILE(5) OVER (ORDER BY f_cnt   ASC)  AS f_score,   -- F 越大越好
        NTILE(5) OVER (ORDER BY m_items ASC)  AS m_score    -- M 越大越好
    FROM rfm
)
SELECT
    CONCAT(r_score, f_score, m_score) AS rfm_group,
    COUNT(*)              AS users,
    ROUND(AVG(r_days), 1) AS avg_r,
    ROUND(AVG(f_cnt), 2)  AS avg_f,
    ROUND(AVG(m_items), 2) AS avg_m
FROM scored
GROUP BY rfm_group
ORDER BY users DESC;

-- 高价值用户（R、F、M 均 ≥ 4 分）
WITH scored AS (
    SELECT user_id, r_days, f_cnt, m_items,
           NTILE(5) OVER (ORDER BY r_days  DESC) AS r_score,
           NTILE(5) OVER (ORDER BY f_cnt   ASC)  AS f_score,
           NTILE(5) OVER (ORDER BY m_items ASC)  AS m_score
    FROM rfm
)
SELECT COUNT(*) AS vip_users
FROM scored
WHERE r_score >= 4 AND f_score >= 4 AND m_score >= 4;

-- 3.8 TOP 类目（品类偏好）
SELECT
    category_id,
    SUM(behavior_type = 'pv')   AS pv_cnt,
    SUM(behavior_type = 'cart') AS cart_cnt,
    SUM(behavior_type = 'buy')  AS buy_cnt,
    ROUND(SUM(behavior_type = 'buy') / SUM(behavior_type = 'pv') * 100, 2) AS buy_rate
FROM ub_clean
GROUP BY category_id
ORDER BY pv_cnt DESC
LIMIT 20;


-- ############################################################################
-- 阶段 ④ BI 可视化：建视图供 Tableau / Power BI 直连
-- ############################################################################

CREATE OR REPLACE VIEW v_funnel AS
SELECT
    SUM(behavior_type = 'pv')   AS pv_cnt,
    SUM(behavior_type = 'cart') AS cart_cnt,
    SUM(behavior_type = 'fav')  AS fav_cnt,
    SUM(behavior_type = 'buy')  AS buy_cnt
FROM ub_clean;

CREATE OR REPLACE VIEW v_daily AS
SELECT d_date,
       COUNT(*) AS cnt,
       COUNT(DISTINCT user_id) AS uv,
       SUM(behavior_type = 'pv') AS pv_cnt,
       SUM(behavior_type = 'buy') AS buy_cnt
FROM ub_clean GROUP BY d_date;

CREATE OR REPLACE VIEW v_hourly AS
SELECT d_hour, behavior_type, COUNT(*) AS cnt
FROM ub_clean GROUP BY d_hour, behavior_type;

CREATE OR REPLACE VIEW v_heatmap AS
SELECT d_date, d_hour, COUNT(*) AS cnt, COUNT(DISTINCT user_id) AS uv
FROM ub_clean GROUP BY d_date, d_hour;

CREATE OR REPLACE VIEW v_top_category AS
SELECT category_id,
       SUM(behavior_type = 'pv') AS pv_cnt,
       SUM(behavior_type = 'buy') AS buy_cnt
FROM ub_clean GROUP BY category_id ORDER BY pv_cnt DESC LIMIT 20;

CREATE OR REPLACE VIEW v_rfm AS
SELECT * FROM rfm;

SELECT table_name FROM information_schema.views WHERE table_schema = 'taobao';


-- ############################################################################
-- 阶段 ⑤ 报告数据导出
--      直接用 Navicat 把上面每个结果集「导出向导 → Excel/CSV」即可
--      或按需 SELECT ... INTO OUTFILE（需 secure_file_priv 授权目录）
-- ############################################################################

-- 示例：导出时段分布（换成实际授权路径）
-- SELECT d_hour, COUNT(*) AS cnt
-- FROM ub_clean GROUP BY d_hour
-- INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/hourly.csv'
-- FIELDS TERMINATED BY ',' ENCLOSED BY '"'
-- LINES TERMINATED BY '\n';

-- 报告要写死的几个数字模版（跑出来后填进去）：
--   样本量 ____ 行 → 去重后 ____ 行 → 剔除时间异常 ____ 条 → 最终干净数据 ____ 行
--   总 PV ____ · UV ____ · 人均浏览 ____ 次
--   浏览→加购 ____% · 加购→购买 ____% · 整体成交转化 ____%
--   活跃高峰时段 ____ 点 · 次日留存 ____%
--   RFM 高价值用户 ____ 人（占购买用户 ____%）
