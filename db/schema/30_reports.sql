-- Отчёты и зарплата курьеров
BEGIN;

CREATE OR REPLACE FUNCTION khromov_food.coefficient_for_count(p_count integer)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, khromov_food
AS $function$
BEGIN
    IF p_count IS NULL OR p_count < 0 THEN
        RAISE EXCEPTION
            'Количество доставок должно быть неотрицательным целым числом, получено %',
            p_count
            USING ERRCODE = '22023';
    END IF;

    RETURN CASE
        WHEN p_count <= 150 THEN 0.1::numeric
        WHEN p_count <= 250 THEN 0.2::numeric
        WHEN p_count <= 500 THEN 0.3::numeric
        ELSE 0.5::numeric
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION khromov_food.get_statistic()
RETURNS TABLE (
    restaurant_name text,
    best_product_name text,
    total_amount numeric,
    avg_amount numeric,
    best_user text
)
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, khromov_food
AS $function$
    WITH delivered AS MATERIALIZED (
        SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
        FROM khromov_food.orders AS o
        WHERE o.status = 'доставлен'
    ),
    restaurant_totals AS (
        SELECT d.restaurant_id,
               SUM(d.total_amount) AS total_amount,
               AVG(d.total_amount) AS avg_amount
        FROM delivered AS d
        GROUP BY d.restaurant_id
    ),
    product_winners AS (
        SELECT DISTINCT ON (d.restaurant_id) d.restaurant_id, s.product_id
        FROM delivered AS d
        JOIN khromov_food.order_structure AS s ON s.order_id = d.order_id
        GROUP BY d.restaurant_id, s.product_id
        ORDER BY d.restaurant_id, SUM(s.quantity) DESC, random()
    ),
    client_winners AS (
        SELECT DISTINCT ON (d.restaurant_id) d.restaurant_id, d.client_id
        FROM delivered AS d
        GROUP BY d.restaurant_id, d.client_id
        ORDER BY d.restaurant_id, COUNT(*) DESC, random()
    )
    SELECT restaurant.restaurant_name::text,
           product.product_name::text,
           COALESCE(totals.total_amount, 0::numeric),
           totals.avg_amount,
           client.login::text
    FROM khromov_food.restaurant AS restaurant
    LEFT JOIN restaurant_totals AS totals
      ON totals.restaurant_id = restaurant.restaurant_id
    LEFT JOIN product_winners AS product_winner
      ON product_winner.restaurant_id = restaurant.restaurant_id
    LEFT JOIN khromov_food.product AS product
      ON product.product_id = product_winner.product_id
    LEFT JOIN client_winners AS client_winner
      ON client_winner.restaurant_id = restaurant.restaurant_id
    LEFT JOIN khromov_food.client AS client
      ON client.client_id = client_winner.client_id;
$function$;

CREATE OR REPLACE PROCEDURE khromov_food.courier_salary()
LANGUAGE plpgsql
SET search_path = pg_catalog, khromov_food
AS $procedure$
DECLARE
    v_month_start timestamptz := date_trunc('month', CURRENT_TIMESTAMP);
    v_month_end timestamptz := v_month_start + INTERVAL '1 month';
    v_year integer := EXTRACT(YEAR FROM v_month_start)::integer;
    v_month integer := EXTRACT(MONTH FROM v_month_start)::integer;
    v_current_coefficient numeric;
    v_next_coefficient numeric;
    v_courier record;
BEGIN
    FOR v_courier IN
        SELECT c.courier_id,
               c.status,
               c.coefficient,
               COALESCE(deliveries.delivered_count, 0::bigint) AS delivered_count,
               COALESCE(deliveries.commission_sum, 0::numeric) AS commission_sum
        FROM khromov_food.courier AS c
        LEFT JOIN (
            SELECT o.courier_id,
                   COUNT(*) AS delivered_count,
                   SUM(o.commission) AS commission_sum
            FROM khromov_food.orders AS o
            WHERE o.status = 'доставлен'
              AND o.delivery_timestamp >= v_month_start
              AND o.delivery_timestamp < v_month_end
            GROUP BY o.courier_id
        ) AS deliveries
          ON deliveries.courier_id = c.courier_id
        ORDER BY c.courier_id
        FOR UPDATE OF c
    LOOP
        -- При повторном расчёте берём коэффициент из выплаты за этот месяц
        SELECT paid.coefficient_used
        INTO v_current_coefficient
        FROM khromov_food.courier_pay AS paid
        WHERE paid.year = v_year
          AND paid.month = v_month
          AND paid.courier_id = v_courier.courier_id
        FOR UPDATE;

        IF NOT FOUND THEN
            v_current_coefficient := v_courier.coefficient;
        END IF;

        -- После 500 доставок коэффициент одинаковый
        v_next_coefficient := khromov_food.coefficient_for_count(
            LEAST(v_courier.delivered_count, 501::bigint)::integer
        );

        INSERT INTO khromov_food.courier_pay AS paid (
            year, month, courier_id, amount, coefficient_used
        )
        VALUES (
            v_year,
            v_month,
            v_courier.courier_id,
            v_current_coefficient * v_courier.commission_sum,
            v_current_coefficient
        )
        ON CONFLICT (year, month, courier_id)
        DO UPDATE
            SET amount = paid.coefficient_used * v_courier.commission_sum;

        IF v_courier.status <> 'уволен' THEN
            UPDATE khromov_food.courier AS c
            SET coefficient = v_next_coefficient
            WHERE c.courier_id = v_courier.courier_id;
        END IF;
    END LOOP;
END;
$procedure$;

CREATE OR REPLACE VIEW khromov_food.how_much_money AS
WITH RECURSIVE
delivered_by_month AS MATERIALIZED (
    SELECT date_trunc('month', o.delivery_timestamp)::date AS month_start,
           SUM(o.order_amount) AS sum_no_commission,
           SUM(o.total_amount) AS sum_with_commission
    FROM khromov_food.orders AS o
    WHERE o.status = 'доставлен'
    GROUP BY date_trunc('month', o.delivery_timestamp)::date
),
calendar_months (month_start, last_month) AS (
    SELECT MIN(month_start), MAX(month_start)
    FROM delivered_by_month
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT (m.month_start + INTERVAL '1 month')::date,
           m.last_month
    FROM calendar_months AS m
    WHERE m.month_start < m.last_month
),
pay_by_month AS (
    SELECT paid.year,
           paid.month,
           SUM(paid.amount) AS courier_pay
    FROM khromov_food.courier_pay AS paid
    GROUP BY paid.year, paid.month
),
monthly_amounts AS (
    SELECT m.month_start,
           COALESCE(delivered.sum_no_commission, 0::numeric) AS sum_no_commission,
           COALESCE(delivered.sum_with_commission, 0::numeric) AS sum_with_commission,
           COALESCE(delivered.sum_with_commission, 0::numeric)
               - COALESCE(delivered.sum_no_commission, 0::numeric) AS commission,
           COALESCE(paid.courier_pay, 0::numeric) AS courier_pay
    FROM calendar_months AS m
    LEFT JOIN delivered_by_month AS delivered
      ON delivered.month_start = m.month_start
    LEFT JOIN pay_by_month AS paid
      ON paid.year = EXTRACT(YEAR FROM m.month_start)::integer
     AND paid.month = EXTRACT(MONTH FROM m.month_start)::integer
),
monthly_with_previous AS (
    SELECT m.month_start,
           m.sum_no_commission,
           m.sum_with_commission,
           m.commission,
           LAG(m.commission) OVER (ORDER BY m.month_start) AS prev_commission,
           m.courier_pay
    FROM monthly_amounts AS m
)
SELECT to_char(m.month_start, 'YYYY-MM')::text AS year_month,
       m.sum_no_commission::numeric AS sum_no_commission,
       m.sum_with_commission::numeric AS sum_with_commission,
       m.commission::numeric AS commission,
       m.prev_commission::numeric AS prev_commission,
       (m.commission - m.prev_commission)::numeric AS commission_diff,
       m.courier_pay::numeric AS courier_pay,
       (m.commission - m.courier_pay)::numeric AS net_profit
FROM monthly_with_previous AS m
ORDER BY m.month_start;

COMMIT;
