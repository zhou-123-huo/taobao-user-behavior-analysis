-- ============================================================================
-- 淘宝用户行为分析 · Power BI 专用补充分层视图
--
-- 用途：让 Power BI 直接拿到「长表结构」的结果集，避免在 DAX 里做复杂的
--       分位计算 / 自连接留存 / 行列转换（这些在 SQL 里做更快更稳）
-- 前提：已存在 ub_clean（干净明细表）与 rfm（R/F/M 原始值表）
-- 执行：mysql -u root -p taobao < 本文件 ；或在 Navicat 查询窗口全选运行
-- ============================================================================

USE taobao;
SET time_zone = '+8:00';


-- ############################################################################
-- 视图 1：v_funnel_long —— 漏斗长表（Power BI 漏斗图直接吃这个）
--   cnt = 行为数口径      uv = 用户数口径（面试优先讲这个）
--   step_order 用于让漏斗按 pv → cart → fav → buy 排序
-- ############################################################################
CREATE OR REPLACE VIEW v_funnel_long AS
SELECT
    behavior_type                                    AS step,
    FIELD(behavior_type, 'pv', 'cart', 'fav', 'buy')  AS step_order,
    COUNT(*)                                          AS cnt,
    COUNT(DISTINCT user_id)                           AS uv
FROM ub_clean
GROUP BY behavior_type;


-- ############################################################################
-- 视图 2：v_daily_behavior —— 日期 × 行为类型（做堆叠柱 / 多线趋势）
-- ############################################################################
CREATE OR REPLACE VIEW v_daily_behavior AS
SELECT
    d_date,
    behavior_type,
    COUNT(*)                AS cnt,
    COUNT(DISTINCT user_id) AS uv
FROM ub_clean
GROUP BY d_date, behavior_type;


-- ############################################################################
-- 视图 3：v_retention —— 留存矩阵（行=首访日，列=间隔天数）
--   new_users 是分母，在同 cohort 的每一行重复出现
--   Power BI 里留存率 = DIVIDE(SUM(retained), SUMX(VALUES(first_date), MIN(new_users)))
-- ############################################################################
CREATE OR REPLACE VIEW v_retention AS
WITH first_day AS (
    SELECT user_id, MIN(d_date) AS f_date
    FROM ub_clean
    GROUP BY user_id
),
cohort AS (
    SELECT f_date, COUNT(*) AS new_users
    FROM first_day
    GROUP BY f_date
),
user_date AS (
    SELECT DISTINCT user_id, d_date
    FROM ub_clean
)
SELECT
    f.f_date                          AS first_date,
    c.new_users                       AS new_users,
    DATEDIFF(ud.d_date, f.f_date)     AS day_diff,
    COUNT(DISTINCT ud.user_id)        AS retained
FROM first_day f
JOIN cohort     c  ON c.f_date   = f.f_date
JOIN user_date  ud ON ud.user_id = f.user_id
GROUP BY f.f_date, c.new_users, DATEDIFF(ud.d_date, f.f_date);


-- ############################################################################
-- 视图 4：rfm_scored + v_rfm_scored —— RFM 五分位打分与人群标签
--   打分方向：r_score 越大 = 越近购买；f_score 越大 = 越频繁；m_score 越大 = 件数越多
-- ############################################################################
DROP TABLE IF EXISTS rfm_scored;
CREATE TABLE rfm_scored AS
SELECT
    user_id,
    r_days,
    f_cnt,
    m_items,
    NTILE(5) OVER (ORDER BY r_days  DESC) AS r_score,
    NTILE(5) OVER (ORDER BY f_cnt   ASC)  AS f_score,
    NTILE(5) OVER (ORDER BY m_items ASC)  AS m_score
FROM rfm;

CREATE OR REPLACE VIEW v_rfm_scored AS
SELECT
    user_id, r_days, f_cnt, m_items,
    r_score, f_score, m_score,
    CONCAT(r_score, f_score, m_score) AS rfm_group,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '01 高价值用户'
        WHEN r_score >= 4 AND f_score >= 4                  THEN '02 潜力深耕用户'
        WHEN r_score >= 4 AND f_score <= 2                  THEN '03 新客/待激活'
        WHEN r_score <= 2 AND f_score >= 4                  THEN '04 重要挽留用户'
        WHEN r_score <= 2 AND f_score <= 2                  THEN '05 流失用户'
        ELSE '06 一般维持用户'
    END AS user_label
FROM rfm_scored;


-- ############################################################################
-- 视图 5：v_category_full —— 全量类目行为汇总（帕累托 / TOP N / 四象限散点）
-- ############################################################################
CREATE OR REPLACE VIEW v_category_full AS
SELECT
    category_id,
    SUM(behavior_type = 'pv')   AS pv_cnt,
    SUM(behavior_type = 'fav')  AS fav_cnt,
    SUM(behavior_type = 'cart') AS cart_cnt,
    SUM(behavior_type = 'buy')  AS buy_cnt,
    COUNT(DISTINCT user_id)     AS uv,
    ROUND(SUM(behavior_type = 'buy') / NULLIF(SUM(behavior_type = 'pv'), 0) * 100, 2) AS buy_rate
FROM ub_clean
GROUP BY category_id;


-- ############################################################################
-- 验收：应看到 6 张视图（原有 6 张 + 新增 5 张 = 11）
-- ############################################################################
SELECT table_name, 'view' AS type
FROM information_schema.views
WHERE table_schema = 'taobao'
ORDER BY table_name;

SELECT * FROM v_funnel_long ORDER BY step_order;
