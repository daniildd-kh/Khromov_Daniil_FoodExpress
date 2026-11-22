-- FOOD-101–110. Интеграционные тесты под inspector на пустой учебной схеме
\set ON_ERROR_STOP on
SET search_path = khromov_food, exts, pg_catalog, pg_temp;
CREATE TEMP TABLE test_log(test_name text PRIMARY KEY, result text NOT NULL);
CREATE TEMP TABLE selected(name text PRIMARY KEY, id uuid NOT NULL);

CREATE FUNCTION pg_temp.check(p_name text, p_ok boolean) RETURNS void LANGUAGE plpgsql AS $test$
BEGIN
    IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', p_name; END IF;
    INSERT INTO test_log VALUES (p_name, 'PASS');
END;
$test$;
CREATE FUNCTION pg_temp.expect_error(p_name text, p_sql text, p_state text) RETURNS void LANGUAGE plpgsql AS $test$
DECLARE actual_state text;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
        IF actual_state = p_state THEN
            INSERT INTO test_log VALUES (p_name, 'PASS'); RETURN;
        END IF;
        RAISE;
    END;
    RAISE EXCEPTION 'FAIL: %, ожидаемая ошибка % не возникла', p_name, p_state;
END;
$test$;
CREATE FUNCTION pg_temp.make_order(
    p_product uuid, p_quantity numeric DEFAULT 1,
    p_status order_status DEFAULT 'доставлен',
    p_delivered timestamptz DEFAULT current_timestamp,
    p_courier uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $test$
DECLARE v_client uuid; v_address uuid; v_courier uuid; v_restaurant uuid; v_price numeric; v_order uuid;
BEGIN
    SELECT client_id, address_id INTO v_client, v_address FROM client_address ORDER BY client_id, address_id LIMIT 1;
    SELECT restaurant_id, price INTO v_restaurant, v_price FROM product WHERE product_id = p_product;
    SELECT coalesce(p_courier, courier_id) INTO v_courier FROM courier WHERE status <> 'уволен' ORDER BY courier_id LIMIT 1;
    INSERT INTO orders(client_id, address_id, courier_id, restaurant_id, order_timestamp, delivery_timestamp, order_amount, status, description)
    VALUES (v_client, v_address, v_courier, v_restaurant,
            coalesce(p_delivered, current_timestamp) - interval '1 hour',
            CASE WHEN p_status = 'доставлен' THEN p_delivered END,
            round(v_price * p_quantity, 2), p_status, 'Проверочный заказ')
    RETURNING order_id INTO v_order;
    INSERT INTO order_structure VALUES (v_order, p_product, p_quantity, v_price);
    RETURN v_order;
END;
$test$;

SELECT pg_temp.check('01_inspector_real_connection', current_user = 'inspector');
SELECT pg_temp.check('02_twelve_tables', (SELECT count(*) = 12 FROM information_schema.tables WHERE table_schema = 'khromov_food' AND table_type = 'BASE TABLE'));
SELECT pg_temp.check('03_eight_enums', (SELECT count(*) = 8 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'khromov_food' AND t.typtype = 'e'));
SELECT pg_temp.check('04_catalog_permissions', EXISTS(SELECT 1 FROM information_schema.tables) AND EXISTS(SELECT 1 FROM pg_catalog.pg_tables));
SELECT pg_temp.check('05_uuid_function', exts.uuid_generate_v4() IS NOT NULL);

DO $test$
DECLARE table_name text; has_rows boolean;
BEGIN
    FOR table_name IN
        SELECT t.table_name FROM information_schema.tables t
        WHERE t.table_schema = 'khromov_food' AND t.table_type = 'BASE TABLE'
    LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM khromov_food.%I)', table_name) INTO has_rows;
        IF has_rows THEN
            RAISE EXCEPTION 'Для тестов требуется пустая схема, в таблице % есть данные', table_name;
        END IF;
    END LOOP;
    PERFORM pg_temp.check('05a_clean_schema', true);
END;
$test$;
CALL insert_test_data(10);
DO $test$
DECLARE tab text; amount bigint;
BEGIN
    FOREACH tab IN ARRAY ARRAY['client','courier','product_category','restaurant'] LOOP
        EXECUTE format('SELECT count(*) FROM khromov_food.%I', tab) INTO amount;
        PERFORM pg_temp.check('06_generator_10_' || tab, amount = 10);
    END LOOP;
    FOREACH tab IN ARRAY ARRAY['address','product','orders','review','payment'] LOOP
        EXECUTE format('SELECT count(*) FROM khromov_food.%I', tab) INTO amount;
        PERFORM pg_temp.check('06_generator_50_' || tab, amount = 50);
    END LOOP;
END;
$test$;
SELECT pg_temp.check('07_courier_pay_60', (SELECT count(*) = 60 FROM courier_pay));
SELECT pg_temp.check('07a_link_counts', (SELECT count(*) = 40 FROM client_address)
    AND (SELECT count(*) = 50 FROM order_structure));
SELECT pg_temp.check('07b_every_courier_and_month_paid', NOT EXISTS (
    SELECT 1 FROM courier c
    CROSS JOIN generate_series(0, 5) AS offset_months(n)
    CROSS JOIN LATERAL (
        SELECT date_trunc('month', current_timestamp) - make_interval(months => offset_months.n) AS month_start
    ) AS m
    LEFT JOIN courier_pay paid ON paid.courier_id = c.courier_id
        AND paid.year = extract(year FROM m.month_start)
        AND paid.month = extract(month FROM m.month_start)
    WHERE paid.courier_id IS NULL
));
SELECT pg_temp.check('07c_every_generated_payout_matches_deliveries', NOT EXISTS (
    SELECT 1 FROM courier_pay paid
    LEFT JOIN orders o ON o.courier_id = paid.courier_id AND o.status = 'доставлен'
        AND extract(year FROM o.delivery_timestamp) = paid.year
        AND extract(month FROM o.delivery_timestamp) = paid.month
    GROUP BY paid.year, paid.month, paid.courier_id, paid.amount, paid.coefficient_used
    HAVING paid.amount <> round(paid.coefficient_used * coalesce(sum(o.commission), 0), 2)
));
WITH months AS (
    SELECT paid.courier_id, paid.coefficient_used, paid.year, paid.month,
        count(o.order_id) AS deliveries
    FROM courier_pay paid
    LEFT JOIN orders o ON o.courier_id = paid.courier_id AND o.status = 'доставлен'
        AND extract(year FROM o.delivery_timestamp) = paid.year
        AND extract(month FROM o.delivery_timestamp) = paid.month
    GROUP BY paid.courier_id, paid.year, paid.month, paid.coefficient_used
), bands AS (
    SELECT months.*, CASE
        WHEN deliveries <= 150 THEN 0.1
        WHEN deliveries <= 250 THEN 0.2
        WHEN deliveries <= 500 THEN 0.3
        ELSE 0.5
    END AS next_coefficient
    FROM months
), history AS (
    SELECT bands.*,
        lag(next_coefficient, 1, 0.1) OVER (PARTITION BY courier_id ORDER BY year, month) AS expected_coefficient,
        row_number() OVER (PARTITION BY courier_id ORDER BY year DESC, month DESC) AS month_index
    FROM bands
)
SELECT pg_temp.check('07d_generated_coefficient_history', NOT EXISTS (
    SELECT 1 FROM history h JOIN courier c USING (courier_id)
    WHERE h.coefficient_used <> h.expected_coefficient
        OR (h.month_index = 1 AND c.status <> 'уволен' AND c.coefficient <> h.next_coefficient)
));
SELECT pg_temp.check('08_active_courier', EXISTS(SELECT 1 FROM courier WHERE status <> 'уволен'));
SELECT pg_temp.check('09_generator_dates', NOT EXISTS(SELECT 1 FROM orders WHERE order_timestamp < date_trunc('month', current_timestamp) - interval '5 months' OR order_timestamp > current_timestamp));
SELECT pg_temp.check('10_generated_md5', NOT EXISTS(SELECT 1 FROM client WHERE password !~ '^[0-9a-f]{32}$'));
CREATE TEMP TABLE first_batch_clients AS SELECT client_id FROM client;
CALL insert_test_data(10);
SELECT pg_temp.check('11_second_generator_counts', (SELECT count(*) = 20 FROM client) AND (SELECT count(*) = 100 FROM orders) AND (SELECT count(*) = 120 FROM courier_pay));
SELECT pg_temp.check('12_first_batch_preserved', NOT EXISTS(SELECT client_id FROM first_batch_clients EXCEPT SELECT client_id FROM client));
SELECT pg_temp.expect_error('13_generator_zero', 'CALL khromov_food.insert_test_data(0)', '22023');
SELECT pg_temp.expect_error('14_generator_negative', 'CALL khromov_food.insert_test_data(-1)', '22023');
SELECT pg_temp.expect_error('15_generator_null', 'CALL khromov_food.insert_test_data(NULL)', '22023');
SELECT pg_temp.check('16_generator_invalid_atomic', (SELECT count(*) = 20 FROM client) AND (SELECT count(*) = 100 FROM orders));

DO $test$
DECLARE rest uuid; category uuid;
BEGIN
    SELECT restaurant_id INTO rest FROM restaurant ORDER BY restaurant_id LIMIT 1;
    SELECT product_category_id INTO category FROM product_category ORDER BY product_category_id LIMIT 1;
    CALL add_product('TEST_PRODUCT', category, 1000, rest, NULL, NULL, 'доступно', 'Тестовое блюдо');
    INSERT INTO selected SELECT 'product', product_id FROM product WHERE product_name = 'TEST_PRODUCT';
    PERFORM pg_temp.check('17_add_product_success', EXISTS(SELECT 1 FROM selected WHERE name = 'product'));
    PERFORM pg_temp.expect_error('18_add_product_missing_restaurant', format('CALL khromov_food.add_product(''X'', %L::uuid, 1000, %L::uuid, NULL, NULL, ''доступно'', ''X'')', category, exts.uuid_generate_v4()), '23503');
    PERFORM pg_temp.expect_error('19_add_product_missing_category', format('CALL khromov_food.add_product(''X'', %L::uuid, 1000, %L::uuid, NULL, NULL, ''доступно'', ''X'')', exts.uuid_generate_v4(), rest), '23503');
    PERFORM pg_temp.expect_error('20_add_product_negative_price', format('CALL khromov_food.add_product(''X'', %L::uuid, -1, %L::uuid, NULL, NULL, ''доступно'', ''X'')', category, rest), '23514');
    PERFORM pg_temp.expect_error('20a_new_rating_is_aggregate', format('CALL khromov_food.add_product(''X'', %L::uuid, 1000, %L::uuid, NULL, 4, ''доступно'', ''X'')', category, rest), '23514');
END;
$test$;

DO $test$
DECLARE prod uuid; ord uuid; client_uuid uuid; r integer;
BEGIN
    SELECT id INTO prod FROM selected WHERE name = 'product';
    FOR r IN 3..5 LOOP
        ord := pg_temp.make_order(prod);
        IF r = 3 THEN INSERT INTO selected VALUES ('order', ord); END IF;
        SELECT client_id INTO client_uuid FROM orders WHERE order_id = ord;
        INSERT INTO review(client_id, review_timestamp, entity_id, entity_type, order_id, description, rating)
        VALUES (client_uuid, current_timestamp, prod, 'блюдо', ord, 'Проверочный отзыв', r);
    END LOOP;
    PERFORM pg_temp.check('21_rating_insert_3_4_5', (SELECT rating = 4 FROM product WHERE product_id = prod));
    DELETE FROM review WHERE entity_id = prod AND entity_type = 'блюдо' AND rating = 3;
    PERFORM pg_temp.check('22_rating_delete_3', (SELECT rating = 4.5 FROM product WHERE product_id = prod));
    UPDATE review SET rating = 1 WHERE entity_id = prod AND entity_type = 'блюдо' AND rating = 5;
    PERFORM pg_temp.check('23_rating_update', (SELECT rating = 2.5 FROM product WHERE product_id = prod));
    UPDATE review SET entity_type = 'ресторан', entity_id = (SELECT restaurant_id FROM product WHERE product_id = prod)
    WHERE entity_id = prod AND entity_type = 'блюдо' AND rating = 1;
    PERFORM pg_temp.check('24_rating_move_old_target', (SELECT rating = 4 FROM product WHERE product_id = prod));
    PERFORM pg_temp.check('25_rating_move_new_target', NOT EXISTS(
        SELECT 1 FROM restaurant r WHERE r.restaurant_id = (SELECT restaurant_id FROM product WHERE product_id = prod)
        AND r.rating IS DISTINCT FROM (SELECT round(avg(v.rating),4) FROM review v WHERE v.entity_type = 'ресторан' AND v.entity_id = r.restaurant_id)));
    DELETE FROM review WHERE entity_id = prod AND entity_type = 'блюдо';
    PERFORM pg_temp.check('26_rating_empty_null', (SELECT rating IS NULL FROM product WHERE product_id = prod));
END;
$test$;

DO $test$
DECLARE ord uuid; attempt uuid; total numeric; status_now order_pay_status;
BEGIN
    SELECT id INTO ord FROM selected WHERE name = 'order';
    SELECT total_amount INTO total FROM orders WHERE order_id = ord;
    INSERT INTO payment(order_id, payment_type, payment_amount, transaction_id, payment_timestamp, status)
    VALUES (ord, 'карта', total, 'TEST_PAYMENT', current_timestamp, 'ошибка') RETURNING payment_id INTO attempt;
    PERFORM pg_temp.check('27_payment_error_aggregate', (SELECT pay_status = 'ошибка' FROM orders WHERE order_id = ord));
    UPDATE payment SET status = 'в_обработке' WHERE payment_id = attempt;
    PERFORM pg_temp.check('28_payment_pending_aggregate', (SELECT pay_status = 'ожидает' FROM orders WHERE order_id = ord));
    UPDATE payment SET status = 'успех' WHERE payment_id = attempt;
    PERFORM pg_temp.check('29_payment_success_aggregate', (SELECT pay_status = 'оплачен' FROM orders WHERE order_id = ord));
    PERFORM pg_temp.expect_error('30_second_success_rejected', format('INSERT INTO khromov_food.payment(order_id,payment_type,payment_amount,transaction_id,payment_timestamp,status) VALUES (%L::uuid,''карта'',%s,''TEST_SECOND'',current_timestamp,''успех'')', ord, total), '23505');
    PERFORM pg_temp.expect_error('31_wrong_payment_amount', format('INSERT INTO khromov_food.payment(order_id,payment_type,payment_amount,transaction_id,payment_timestamp,status) VALUES (%L::uuid,''карта'',1,''TEST_BAD_AMOUNT'',current_timestamp,''ошибка'')', ord), '23514');
    PERFORM pg_temp.expect_error('32_transaction_id_unique', format('INSERT INTO khromov_food.payment(order_id,payment_type,payment_amount,transaction_id,payment_timestamp,status) VALUES (%L::uuid,''карта'',%s,''TEST_PAYMENT'',current_timestamp,''ошибка'')', ord, total), '23505');
    DELETE FROM payment WHERE payment_id = attempt;
    PERFORM pg_temp.check('33_zero_attempts_pending', (SELECT pay_status = 'ожидает' FROM orders WHERE order_id = ord));
END;
$test$;

SELECT pg_temp.expect_error('34_quantity_positive', 'UPDATE khromov_food.order_structure SET quantity = 0 WHERE order_id = (SELECT id FROM selected WHERE name = ''order'')', '23514');
SELECT pg_temp.expect_error('35_delivery_not_before_creation', 'UPDATE khromov_food.orders SET delivery_timestamp = order_timestamp - interval ''1 second'' WHERE order_id = (SELECT id FROM selected WHERE name = ''order'')', '23514');
SELECT pg_temp.expect_error('35a_product_restaurant_guard', 'UPDATE khromov_food.product SET restaurant_id=(SELECT restaurant_id FROM khromov_food.restaurant WHERE restaurant_id<>(SELECT restaurant_id FROM khromov_food.product WHERE product_id=(SELECT id FROM selected WHERE name=''product'')) LIMIT 1) WHERE product_id=(SELECT id FROM selected WHERE name=''product'')', '23514');
DO $test$
DECLARE ord uuid; owner_uuid uuid; wrong_client uuid; wrong_product uuid;
BEGIN
    SELECT id INTO ord FROM selected WHERE name='order';
    SELECT client_id INTO owner_uuid FROM orders WHERE order_id=ord;
    SELECT client_id INTO wrong_client FROM client WHERE client_id<>owner_uuid LIMIT 1;
    SELECT product_id INTO wrong_product FROM product WHERE product_id<>(SELECT id FROM selected WHERE name='product') LIMIT 1;
    PERFORM pg_temp.expect_error('35b_review_wrong_owner', format('INSERT INTO khromov_food.review(client_id,review_timestamp,entity_id,entity_type,order_id,description,rating) VALUES(%L::uuid,current_timestamp,%L::uuid,''заказ'',%L::uuid,''X'',4)',wrong_client,ord,ord), '23514');
    PERFORM pg_temp.expect_error('35c_review_wrong_product', format('INSERT INTO khromov_food.review(client_id,review_timestamp,entity_id,entity_type,order_id,description,rating) VALUES(%L::uuid,current_timestamp,%L::uuid,''блюдо'',%L::uuid,''X'',4)',owner_uuid,wrong_product,ord), '23514');
END;
$test$;
DO $test$
DECLARE ord uuid; foreign_address uuid;
BEGIN
    SELECT id INTO ord FROM selected WHERE name = 'order';
    SELECT ca.address_id INTO foreign_address FROM client_address ca
    WHERE ca.client_id <> (SELECT client_id FROM orders WHERE order_id = ord) LIMIT 1;
    PERFORM pg_temp.expect_error('36_foreign_client_address', format('UPDATE khromov_food.orders SET address_id=%L::uuid WHERE order_id=%L::uuid',foreign_address,ord), '23503');
END;
$test$;
DO $test$
DECLARE row_data orders%ROWTYPE;
BEGIN
    SELECT * INTO row_data FROM orders LIMIT 1;
    BEGIN
        INSERT INTO orders(courier_id,client_id,address_id,restaurant_id,order_timestamp,order_amount,status,description)
        VALUES(row_data.courier_id,row_data.client_id,row_data.address_id,row_data.restaurant_id,current_timestamp,1000,'создан','Пустой заказ');
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Пустой заказ не был отклонён';
    EXCEPTION WHEN check_violation THEN
        INSERT INTO test_log VALUES ('37_empty_order_rejected_at_commit_check','PASS');
    END;
    SET CONSTRAINTS ALL DEFERRED;
END;
$test$;

SELECT pg_temp.check('38_coefficient_boundaries',
    coefficient_for_count(0)=0.1 AND coefficient_for_count(150)=0.1
    AND coefficient_for_count(151)=0.2 AND coefficient_for_count(250)=0.2
    AND coefficient_for_count(251)=0.3 AND coefficient_for_count(500)=0.3
    AND coefficient_for_count(501)=0.5);
DO $test$
DECLARE c uuid; fired uuid; prod uuid; counter integer;
BEGIN
    SELECT id INTO prod FROM selected WHERE name='product';
    INSERT INTO courier(fio,phone_number,status,hire_date,coefficient)
    VALUES('Учебный Курьер Зарплаты','+79990000001','свободен',current_date-30,0.3) RETURNING courier_id INTO c;
    INSERT INTO selected VALUES('salary_courier',c);
    FOR counter IN 1..151 LOOP PERFORM pg_temp.make_order(prod,1,'доставлен',current_timestamp,c); END LOOP;
    INSERT INTO courier(fio,phone_number,status,hire_date,dismissal_date,coefficient)
    VALUES('Учебный Уволенный Курьер','+79990000002','уволен',current_date-30,current_date,0.4) RETURNING courier_id INTO fired;
    INSERT INTO selected VALUES('fired_courier',fired);
    PERFORM pg_temp.make_order(prod,1,'доставлен',current_timestamp,fired);
END;
$test$;
CALL courier_salary();
SELECT pg_temp.check('39_salary_current_coefficient', EXISTS(SELECT 1 FROM courier_pay p WHERE p.courier_id=(SELECT id FROM selected WHERE name='salary_courier') AND p.year=extract(year FROM current_timestamp) AND p.month=extract(month FROM current_timestamp) AND p.amount=4530 AND p.coefficient_used=0.3));
SELECT pg_temp.check('40_salary_next_coefficient', (SELECT coefficient=0.2 FROM courier WHERE courier_id=(SELECT id FROM selected WHERE name='salary_courier')));
SELECT pg_temp.check('41_fired_paid_no_coefficient_change', EXISTS(SELECT 1 FROM courier_pay p JOIN courier c USING(courier_id) WHERE c.courier_id=(SELECT id FROM selected WHERE name='fired_courier') AND p.year=extract(year FROM current_timestamp) AND p.month=extract(month FROM current_timestamp) AND p.amount=40 AND p.coefficient_used=0.4 AND c.coefficient=0.4));
CREATE TEMP TABLE salary_before AS SELECT * FROM courier_pay;
CALL courier_salary();
SELECT pg_temp.check('42_salary_repeat_idempotent', NOT EXISTS((SELECT * FROM courier_pay EXCEPT SELECT * FROM salary_before) UNION ALL (SELECT * FROM salary_before EXCEPT SELECT * FROM courier_pay)));
SELECT pg_temp.make_order((SELECT id FROM selected WHERE name='product'),1,'доставлен',current_timestamp,(SELECT id FROM selected WHERE name='salary_courier'));
CALL courier_salary();
SELECT pg_temp.check('43_salary_repeat_new_delivery_old_coefficient', EXISTS(SELECT 1 FROM courier_pay WHERE courier_id=(SELECT id FROM selected WHERE name='salary_courier') AND year=extract(year FROM current_timestamp) AND month=extract(month FROM current_timestamp) AND amount=4560 AND coefficient_used=0.3));

SELECT pg_temp.check('44_statistic_one_row_per_restaurant', (SELECT count(*) FROM get_statistic())=(SELECT count(*) FROM restaurant));
SELECT pg_temp.check('45_statistic_totals', (SELECT coalesce(sum(total_amount),0) FROM get_statistic())=(SELECT coalesce(sum(total_amount),0) FROM orders WHERE status='доставлен'));
SELECT pg_temp.check('46_statistic_best_nonnull_with_orders', NOT EXISTS(SELECT 1 FROM get_statistic() WHERE total_amount > 0 AND (best_product_name IS NULL OR best_user IS NULL OR avg_amount IS NULL)));

-- Изолируем проверку календарных пробелов от предыдущих синтетических фикстур
CALL erase_test_data();
CALL insert_test_data(1);
BEGIN;
DELETE FROM review;
DELETE FROM payment;
DELETE FROM order_structure;
DELETE FROM orders;
DELETE FROM courier_pay;
UPDATE product SET price=1000;
COMMIT;
SELECT pg_temp.make_order((SELECT product_id FROM product LIMIT 1),1,'доставлен',date_trunc('month',current_timestamp)-interval '2 months'+interval '1 day');
SELECT pg_temp.make_order((SELECT product_id FROM product LIMIT 1),1,'доставлен',current_timestamp);
SELECT pg_temp.check('47_calendar_gap_three_months', (SELECT count(*)=3 FROM how_much_money));
SELECT pg_temp.check('48_gap_month_zero_and_lag', EXISTS(SELECT 1 FROM how_much_money WHERE year_month=to_char(current_timestamp-interval '1 month','YYYY-MM') AND commission=0 AND sum_no_commission=0 AND sum_with_commission=0 AND courier_pay=0 AND net_profit=0 AND prev_commission=100 AND commission_diff=-100));
SELECT pg_temp.check('49_first_month_previous_null', (SELECT prev_commission IS NULL AND commission_diff IS NULL FROM how_much_money ORDER BY year_month LIMIT 1));
INSERT INTO courier_pay(year,month,courier_id,amount,coefficient_used)
SELECT extract(year FROM current_timestamp-interval '1 month')::integer,extract(month FROM current_timestamp-interval '1 month')::integer,courier_id,50,0.1 FROM courier LIMIT 1;
SELECT pg_temp.check('50_gap_actual_pay_not_hidden', EXISTS(SELECT 1 FROM how_much_money WHERE year_month=to_char(current_timestamp-interval '1 month','YYYY-MM') AND courier_pay=50 AND net_profit=-50));

CREATE TEMP TABLE objects_before AS
SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='khromov_food') AS routines,
       (SELECT count(*) FROM pg_trigger WHERE tgrelid IN (SELECT oid FROM pg_class WHERE relnamespace='khromov_food'::regnamespace) AND NOT tgisinternal) AS triggers;
CALL erase_test_data();
CALL erase_test_data();
DO $test$
DECLARE tab record; amount bigint;
BEGIN
    FOR tab IN SELECT table_name FROM information_schema.tables WHERE table_schema='khromov_food' AND table_type='BASE TABLE' LOOP
        EXECUTE format('SELECT count(*) FROM khromov_food.%I',tab.table_name) INTO amount;
        PERFORM pg_temp.check('51_erase_empty_'||tab.table_name,amount=0);
    END LOOP;
END;
$test$;
SELECT pg_temp.check('52_no_deliveries_empty_report', (SELECT count(*)=0 FROM how_much_money));
SELECT pg_temp.check('53_erase_preserves_routines', (SELECT routines FROM objects_before)=(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='khromov_food'));
SELECT pg_temp.check('54_erase_preserves_triggers', (SELECT triggers FROM objects_before)=(SELECT count(*) FROM pg_trigger WHERE tgrelid IN (SELECT oid FROM pg_class WHERE relnamespace='khromov_food'::regnamespace) AND NOT tgisinternal));
TABLE test_log;
SELECT count(*) AS actually_executed_checks FROM test_log;
