-- Тестовые данные и добавление блюда
BEGIN;
SET LOCAL search_path = khromov_food, exts, pg_catalog;

CREATE PROCEDURE insert_test_data(value integer)
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
DECLARE
    v_addresses uuid[] := ARRAY[]::uuid[];
    v_rest_status restaurant_status[] := enum_range(NULL::restaurant_status);
    v_product_status product_status[] := enum_range(NULL::product_status);
    v_courier_status courier_status[] := enum_range(NULL::courier_status);
    v_order_status order_status[] := enum_range(NULL::order_status);
    v_payment_status payment_status[] := enum_range(NULL::payment_status);
    v_payment_type payment_type[] := enum_range(NULL::payment_type);
    v_review_type review_entity_type[] := enum_range(NULL::review_entity_type);
    v_client uuid;
    v_courier uuid;
    v_category uuid;
    v_restaurant uuid;
    v_address uuid;
    v_order uuid;
    v_target uuid;
    v_product uuid;
    v_phone varchar(24); v_token text;
    v_anchor timestamptz := date_trunc('month', current_timestamp) - interval '5 months';
    v_month timestamptz; v_until timestamptz; v_created timestamptz; v_finished timestamptz;
    v_coefficient numeric; v_commission numeric; v_count integer;
    v_quantity numeric; v_price numeric; v_amount numeric;
    v_entity review_entity_type; v_status courier_status;
    i integer; j integer; m integer;
BEGIN
    IF value IS NULL OR value < 1 THEN
        RAISE EXCEPTION 'insert_test_data(value): value должен быть положительным целым числом' USING ERRCODE = '22023';
    END IF;
    FOR i IN 1..value LOOP
        v_client := exts.uuid_generate_v4();
        v_token := replace(v_client::text, '-', '');
        LOOP
            v_phone := '+7' || lpad(floor(random() * 10000000000)::bigint::text, 10, '0');
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client WHERE phone_number = v_phone);
        END LOOP;
        INSERT INTO client(client_id, login, password, phone_number)
        VALUES (v_client, 'client_' || v_token, md5(random()::text), v_phone);

        v_status := v_courier_status[1 + ((i - 1) % array_length(v_courier_status, 1))];
        INSERT INTO courier(fio, phone_number, status, hire_date, dismissal_date, coefficient)
        VALUES ('Тестовый Курьер ' || left(v_token, 12), v_phone, v_status,
                v_anchor::date, CASE WHEN v_status = 'уволен' THEN current_date END, 0.1)
        RETURNING courier_id INTO v_courier;

        INSERT INTO product_category(product_category_name)
        VALUES ('Категория ' || left(v_token, 20))
        RETURNING product_category_id INTO v_category;

        INSERT INTO address(street, house_number, apartment_office)
        VALUES ('Учебная ' || left(v_token, 24), '1', NULL) RETURNING address_id INTO v_address;
        INSERT INTO restaurant(restaurant_name, address_id, description, work_start, work_end, company_details, status)
        VALUES ('Ресторан ' || left(v_token, 24), v_address, 'Тестовый ресторан', '09:00', '22:00',
                'Учебные реквизиты ' || v_token, v_rest_status[1 + ((i - 1) % array_length(v_rest_status, 1))])
        RETURNING restaurant_id INTO v_restaurant;

        FOR j IN 1..4 LOOP
            INSERT INTO address(street, house_number, apartment_office)
            VALUES ('Учебная ' || left(v_token, 24), (j + 1)::text, CASE WHEN j % 2 = 0 THEN j::text END)
            RETURNING address_id INTO v_address;
            v_addresses[j] := v_address;
            INSERT INTO client_address(client_id, address_id) VALUES (v_client, v_address);
        END LOOP;

        FOR j IN 1..5 LOOP
            INSERT INTO product(product_name, product_category_id, price, restaurant_id, photo_url, rating, status, description)
            VALUES ('Блюдо ' || left(v_token, 20) || ' ' || j, v_category, 1000 + j * 100, v_restaurant,
                    CASE WHEN j % 2 = 0 THEN 'https://example.invalid/food/' || v_token || '/' || j END,
                    NULL, v_product_status[1 + ((j - 1) % array_length(v_product_status, 1))], 'Тестовое блюдо')
            RETURNING product_id, price INTO v_product, v_price;

            v_quantity := CASE WHEN j % 2 = 0 THEN 1.5 ELSE 1 END;
            v_amount := round(v_quantity * v_price, 2);
            v_month := v_anchor + make_interval(months => (i * 5 + j) % 6);
            v_until := greatest(v_month, least(v_month + interval '1 month', current_timestamp) - interval '2 hours');
            v_created := v_month + random() * (v_until - v_month);
            v_finished := CASE WHEN v_order_status[j] = 'доставлен' THEN least(v_created + interval '30 minutes', current_timestamp) END;
            INSERT INTO orders(courier_id, client_id, address_id, restaurant_id, order_timestamp, delivery_timestamp, order_amount, status, description)
            VALUES (v_courier, v_client, v_addresses[1 + (j - 1) % 4],
                    v_restaurant, v_created, v_finished, v_amount, v_order_status[j], 'Тестовый заказ')
            RETURNING order_id INTO v_order;
            INSERT INTO order_structure(order_id, product_id, quantity, unit_price)
            VALUES (v_order, v_product, v_quantity, v_price);
            INSERT INTO payment(order_id, payment_type, payment_amount, transaction_id, payment_timestamp, status)
            VALUES (v_order, v_payment_type[1 + ((j - 1) % array_length(v_payment_type, 1))],
                    v_amount + round(v_amount * 0.10, 2), 'test_' || exts.uuid_generate_v4()::text,
                    least(v_created + interval '1 minute', current_timestamp),
                    v_payment_status[1 + ((j - 1) % array_length(v_payment_status, 1))]);
            v_entity := v_review_type[1 + ((j - 1) % array_length(v_review_type, 1))];
            v_target := CASE v_entity WHEN 'блюдо' THEN v_product WHEN 'ресторан' THEN v_restaurant ELSE v_order END;
            INSERT INTO review(client_id, review_timestamp, entity_id, entity_type, order_id, description, photo_url, rating)
            VALUES (v_client, least(v_created + interval '45 minutes', current_timestamp), v_target, v_entity,
                    v_order, 'Тестовый отзыв', NULL, 1 + ((i + j) % 5));
        END LOOP;

        v_coefficient := 0.1;
        FOR m IN 0..5 LOOP
            v_month := v_anchor + make_interval(months => m);
            SELECT count(*)::integer, coalesce(sum(commission), 0)
              INTO v_count, v_commission FROM orders
             WHERE courier_id = v_courier AND status = 'доставлен'
               AND delivery_timestamp >= v_month AND delivery_timestamp < v_month + interval '1 month';
            INSERT INTO courier_pay(year, month, courier_id, amount, coefficient_used)
            VALUES (extract(year FROM v_month)::integer, extract(month FROM v_month)::integer,
                    v_courier, round(v_coefficient * v_commission, 2), v_coefficient);
            v_coefficient := coefficient_for_count(v_count);
        END LOOP;
        UPDATE courier SET coefficient = v_coefficient WHERE courier_id = v_courier AND status <> 'уволен';
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM courier WHERE status <> 'уволен') THEN
        RAISE EXCEPTION 'Генератор обязан оставить хотя бы одного активного курьера';
    END IF;
END;
$fn$;

CREATE PROCEDURE erase_test_data()
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
BEGIN
    DELETE FROM review;
    DELETE FROM payment;
    DELETE FROM order_structure;
    DELETE FROM orders;
    DELETE FROM client_address;
    DELETE FROM courier_pay;
    DELETE FROM product;
    DELETE FROM product_category;
    DELETE FROM restaurant;
    DELETE FROM courier;
    DELETE FROM client;
    DELETE FROM address;
END;
$fn$;

CREATE PROCEDURE add_product(
    p_product_name varchar, p_product_category_id uuid, p_price numeric,
    p_restaurant_id uuid, p_photo_url text, p_rating numeric,
    p_status product_status, p_description text
)
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id = p_restaurant_id) THEN
        RAISE EXCEPTION 'Ресторан % не существует', p_restaurant_id USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM product_category WHERE product_category_id = p_product_category_id) THEN
        RAISE EXCEPTION 'Категория % не существует', p_product_category_id USING ERRCODE = '23503';
    END IF;
    IF p_price < 0 THEN RAISE EXCEPTION 'Цена блюда не может быть отрицательной' USING ERRCODE = '23514'; END IF;
    IF p_rating IS NOT NULL THEN
        RAISE EXCEPTION 'Для нового блюда без отзывов рейтинг должен быть NULL по BR-9.7' USING ERRCODE = '23514';
    END IF;
    INSERT INTO product(product_name, product_category_id, price, restaurant_id, photo_url, rating, status, description)
    VALUES (p_product_name, p_product_category_id, p_price, p_restaurant_id, p_photo_url, p_rating, p_status, p_description);
END;
$fn$;
COMMIT;
