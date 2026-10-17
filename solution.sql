/* Microsoft SQL Server. Run each numbered batch independently.
   date_close is the first non-working day. Current day is excluded from rolling periods.
   Monetary/quantity fields are assumed non-NULL. See docs/Конспект.md for alternatives.
   IDs must be BIGINT in a real schema: supplied examples exceed signed INT. */

-- 1. Case-insensitive search, including databases with case-sensitive collation.
SELECT p.name AS product_name, p.shelf_life
FROM dbo.product AS p
WHERE p.name COLLATE Cyrillic_General_100_CI_AS LIKE N'%самокат%'
  AND p.shelf_life <= 7;
GO

-- 2. Open warehouses as of today. Future openings are excluded.
DECLARE @today date = CONVERT(date, GETDATE());
SELECT w.city, COUNT_BIG(*) AS warehouse_count
FROM dbo.warehouses AS w
WHERE w.date_open <= @today
  AND (w.date_close IS NULL OR w.date_close > @today)
GROUP BY w.city
HAVING COUNT_BIG(*) > 50
ORDER BY w.city;
GO

-- 3. June 2020. Every warehouse active at least one day participates, including zero sales.
WITH active AS (
 SELECT warehouse_id, city FROM dbo.warehouses
 WHERE date_open < '20200701'
   AND (date_close IS NULL OR date_close > '20200601')
), sku AS (
 SELECT warehouse_id, COUNT(DISTINCT product_id) AS sku_count
 FROM dbo.order_line
 WHERE [date] >= '20200601' AND [date] < '20200701' AND quantity > 0
 GROUP BY warehouse_id
)
SELECT a.city, COUNT_BIG(*) AS warehouse_count,
       AVG(CONVERT(decimal(19,4), COALESCE(s.sku_count, 0))) AS avg_sku_per_warehouse
FROM active AS a LEFT JOIN sku AS s ON s.warehouse_id = a.warehouse_id
GROUP BY a.city ORDER BY a.city;
GO

-- 4. Unique users are counted directly at city/company level, never summed across cities.
SELECT CASE WHEN GROUPING(w.city) = 1 THEN N'Компания' ELSE w.city END AS city_or_company,
       DATEFROMPARTS(YEAR(o.[date]), MONTH(o.[date]), 1) AS month_start,
       COUNT_BIG(*) AS order_count,
       COUNT(DISTINCT o.user_id) AS client_count
FROM dbo.orders AS o
LEFT JOIN dbo.warehouses AS w ON w.warehouse_id = o.warehouse_id
WHERE o.[date] >= '20210101' AND o.[date] < '20220101'
GROUP BY GROUPING SETS (
 (w.city, DATEFROMPARTS(YEAR(o.[date]), MONTH(o.[date]), 1)),
 (DATEFROMPARTS(YEAR(o.[date]), MONTH(o.[date]), 1))
)
ORDER BY month_start, city_or_company;
GO

-- 5. Previous 14 complete calendar days. City check is weighted by order count.
DECLARE @today date = CONVERT(date, GETDATE());
WITH by_warehouse AS (
 SELECT w.warehouse_id, w.name, w.city,
        SUM(CONVERT(decimal(28,4), o.paid_amount)) AS sales,
        COUNT_BIG(*) AS orders_count
 FROM dbo.orders AS o
 JOIN dbo.warehouses AS w ON w.warehouse_id = o.warehouse_id
 WHERE o.[date] >= DATEADD(day, -14, @today) AND o.[date] < @today
 GROUP BY w.warehouse_id, w.name, w.city
), checks AS (
 SELECT *, sales / NULLIF(orders_count, 0) AS avg_warehouse_order,
        SUM(sales) OVER (PARTITION BY city)
        / NULLIF(SUM(orders_count) OVER (PARTITION BY city), 0) AS avg_city_order
 FROM by_warehouse
)
SELECT name AS warehouse_name, city, avg_warehouse_order, avg_city_order
FROM checks WHERE avg_warehouse_order > avg_city_order
ORDER BY warehouse_name COLLATE Cyrillic_General_100_CI_AS, city, warehouse_id;
GO

-- 6. Previous 28 complete days, all loss articles, including groups without sales.
DECLARE @today date = CONVERT(date, GETDATE());
WITH sales AS (
 SELECT p.group1, p.group2, SUM(CONVERT(decimal(28,4), ol.paid_amount)) AS sales_amount
 FROM dbo.order_line AS ol JOIN dbo.product AS p ON p.product_id = ol.product_id
 WHERE ol.[date] >= DATEADD(day, -28, @today) AND ol.[date] < @today
 GROUP BY p.group1, p.group2
), losses AS (
 SELECT p.group1, p.group2, SUM(CONVERT(decimal(28,4), l.amount)) AS loss_amount
 FROM dbo.lost AS l JOIN dbo.product AS p ON p.product_id = l.product_id
 WHERE l.[date] >= DATEADD(day, -28, @today) AND l.[date] < @today
 GROUP BY p.group1, p.group2
), combined AS (
 SELECT group1, group2, SUM(sales_amount) AS sales_amount, SUM(loss_amount) AS loss_amount
 FROM (
  SELECT group1, group2, sales_amount, CONVERT(decimal(28,4), 0) AS loss_amount FROM sales
  UNION ALL
  SELECT group1, group2, CONVERT(decimal(28,4), 0), loss_amount FROM losses
 ) AS u GROUP BY group1, group2
)
SELECT group1, group2,
       100.0 * loss_amount / NULLIF(sales_amount, 0) AS loss_pct_of_sales,
       100.0 * loss_amount / NULLIF(SUM(loss_amount) OVER (), 0) AS share_of_company_loss_pct
FROM combined ORDER BY group1, group2;
GO

-- 7. May 2021, Moscow. One common denominator: all warehouses active during May.
-- Top 10 sales OR top 10 losses, ties resolved by product_id (at most 20 rows per group).
WITH active AS (
 SELECT warehouse_id FROM dbo.warehouses
 WHERE city COLLATE Cyrillic_General_100_CI_AS = N'Москва'
   AND date_open < '20210601' AND (date_close IS NULL OR date_close > '20210501')
), denominator AS (
 SELECT COUNT_BIG(*) AS warehouse_count FROM active
), facts AS (
 SELECT ol.product_id, SUM(CONVERT(decimal(28,4), ol.paid_amount)) AS sales_amount,
        CONVERT(decimal(28,4), 0) AS loss_amount
 FROM dbo.order_line AS ol JOIN active AS a ON a.warehouse_id = ol.warehouse_id
 WHERE ol.[date] >= '20210501' AND ol.[date] < '20210601'
 GROUP BY ol.product_id
 UNION ALL
 SELECT l.product_id, CONVERT(decimal(28,4), 0), SUM(CONVERT(decimal(28,4), l.amount))
 FROM dbo.lost AS l JOIN active AS a ON a.warehouse_id = l.warehouse_id
 WHERE l.[date] >= '20210501' AND l.[date] < '20210601'
 GROUP BY l.product_id
), totals AS (
 SELECT product_id, SUM(sales_amount) AS sales_amount, SUM(loss_amount) AS loss_amount
 FROM facts GROUP BY product_id
), ranked AS (
 SELECT p.group1, p.name, p.product_id, t.sales_amount, t.loss_amount,
        t.sales_amount / NULLIF(d.warehouse_count, 0) AS sales_per_warehouse,
        t.loss_amount / NULLIF(d.warehouse_count, 0) AS loss_per_warehouse,
        ROW_NUMBER() OVER(PARTITION BY p.group1 ORDER BY t.sales_amount DESC, p.product_id) AS sales_rank,
        ROW_NUMBER() OVER(PARTITION BY p.group1 ORDER BY t.loss_amount DESC, p.product_id) AS loss_rank
 FROM totals AS t JOIN dbo.product AS p ON p.product_id = t.product_id
 CROSS JOIN denominator AS d
)
SELECT group1, name AS product_name, sales_per_warehouse, sales_rank,
       loss_per_warehouse, loss_rank
FROM ranked
WHERE (sales_rank <= 10 AND sales_amount > 0) OR (loss_rank <= 10 AND loss_amount > 0)
ORDER BY group1, sales_rank, loss_rank, product_id;
GO
