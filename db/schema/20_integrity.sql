-- Проверки заказов и платежей, пересчёт рейтингов FOOD-105
BEGIN;
SET LOCAL search_path = khromov_food, exts, pg_catalog;

CREATE FUNCTION assert_order_contents(p_order_id uuid) RETURNS void
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
DECLARE v_order orders%ROWTYPE; v_count integer; v_sum numeric;
BEGIN
    SELECT * INTO v_order FROM orders WHERE order_id = p_order_id;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT count(*), round(sum(quantity * unit_price), 2)
      INTO v_count, v_sum FROM order_structure WHERE order_id = p_order_id;
    IF v_count = 0 THEN RAISE EXCEPTION 'Заказ % должен содержать хотя бы одну позицию', p_order_id USING ERRCODE = '23514'; END IF;
    IF v_sum <> v_order.order_amount THEN RAISE EXCEPTION 'Сумма заказа % не равна сумме его позиций', p_order_id USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM order_structure s JOIN product p USING (product_id)
               WHERE s.order_id = p_order_id AND p.restaurant_id <> v_order.restaurant_id) THEN
        RAISE EXCEPTION 'Все блюда заказа % должны принадлежать его ресторану', p_order_id USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM payment WHERE order_id = p_order_id AND payment_amount <> v_order.total_amount) THEN
        RAISE EXCEPTION 'Сумма оплаты заказа % отличается от общей суммы', p_order_id USING ERRCODE = '23514';
    END IF;
    IF v_order.pay_status <> (
        SELECT CASE
            WHEN bool_or(status = 'успех') THEN 'оплачен'
            WHEN bool_and(status = 'ошибка') THEN 'ошибка'
            ELSE 'ожидает'
        END::order_pay_status
        FROM payment WHERE order_id = p_order_id
    ) THEN RAISE EXCEPTION 'Статус оплаты заказа % не согласован с попытками', p_order_id USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM review r WHERE r.order_id = p_order_id AND (
        (r.entity_type = 'блюдо' AND NOT EXISTS (SELECT 1 FROM order_structure s WHERE s.order_id = p_order_id AND s.product_id = r.entity_id))
        OR (r.entity_type = 'ресторан' AND r.entity_id <> v_order.restaurant_id)
        OR (r.entity_type = 'заказ' AND r.entity_id <> p_order_id))) THEN
        RAISE EXCEPTION 'Объект отзыва больше не соответствует заказу %', p_order_id USING ERRCODE = '23514';
    END IF;
END;
$fn$;

CREATE FUNCTION order_contents_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
BEGIN
    IF TG_OP <> 'INSERT' THEN PERFORM assert_order_contents(OLD.order_id); END IF;
    IF TG_OP <> 'DELETE' THEN PERFORM assert_order_contents(NEW.order_id); END IF;
    RETURN NULL;
END;
$fn$;
CREATE CONSTRAINT TRIGGER order_complete AFTER INSERT OR UPDATE ON orders
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_contents_change();
CREATE CONSTRAINT TRIGGER order_structure_complete AFTER INSERT OR UPDATE OR DELETE ON order_structure
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_contents_change();

CREATE FUNCTION validate_payment() RETURNS trigger
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
DECLARE v_total numeric;
BEGIN
    SELECT total_amount INTO v_total FROM orders WHERE order_id = NEW.order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Заказ для оплаты не найден' USING ERRCODE = '23503'; END IF;
    IF NEW.payment_amount <> v_total THEN RAISE EXCEPTION 'Сумма оплаты должна равняться общей сумме заказа' USING ERRCODE = '23514'; END IF;
    RETURN NEW;
END;
$fn$;
CREATE TRIGGER payment_validate BEFORE INSERT OR UPDATE ON payment FOR EACH ROW EXECUTE FUNCTION validate_payment();

CREATE FUNCTION refresh_pay_status(p_order_id uuid) RETURNS void
LANGUAGE sql SET search_path = khromov_food, exts, pg_catalog AS $fn$
    UPDATE orders SET pay_status = (
        SELECT CASE
            WHEN bool_or(status = 'успех') THEN 'оплачен'
            WHEN bool_and(status = 'ошибка') THEN 'ошибка'
            ELSE 'ожидает'
        END::order_pay_status
        FROM payment WHERE order_id = p_order_id
    ) WHERE order_id = p_order_id;
$fn$;
CREATE FUNCTION payment_status_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
BEGIN
    IF TG_OP <> 'INSERT' THEN PERFORM refresh_pay_status(OLD.order_id); END IF;
    IF TG_OP <> 'DELETE' THEN PERFORM refresh_pay_status(NEW.order_id); END IF;
    RETURN NULL;
END;
$fn$;
CREATE TRIGGER payment_status_refresh AFTER INSERT OR UPDATE OR DELETE ON payment FOR EACH ROW EXECUTE FUNCTION payment_status_change();

CREATE FUNCTION validate_review() RETURNS trigger
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
DECLARE v_order orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM orders WHERE order_id = NEW.order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Заказ для отзыва не найден' USING ERRCODE = '23503'; END IF;
    IF NEW.client_id <> v_order.client_id THEN RAISE EXCEPTION 'Отзыв может оставить только клиент этого заказа' USING ERRCODE = '23514'; END IF;
    IF NEW.entity_type = 'блюдо' AND NOT EXISTS (SELECT 1 FROM order_structure WHERE order_id = NEW.order_id AND product_id = NEW.entity_id) THEN
        RAISE EXCEPTION 'Отзыв допустим только на блюдо из указанного заказа' USING ERRCODE = '23514';
    ELSIF NEW.entity_type = 'ресторан' AND NEW.entity_id <> v_order.restaurant_id THEN
        RAISE EXCEPTION 'Ресторан отзыва не соответствует заказу' USING ERRCODE = '23514';
    ELSIF NEW.entity_type = 'заказ' AND NEW.entity_id <> NEW.order_id THEN
        RAISE EXCEPTION 'Объект отзыва должен совпадать с заказом' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$fn$;
CREATE TRIGGER review_validate BEFORE INSERT OR UPDATE ON review FOR EACH ROW EXECUTE FUNCTION validate_review();

CREATE FUNCTION validate_aggregate_rating() RETURNS trigger
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
DECLARE v_expected numeric;
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        SELECT round(avg(rating),4) INTO v_expected FROM review WHERE entity_type='блюдо' AND entity_id=NEW.product_id;
    ELSE
        SELECT round(avg(rating),4) INTO v_expected FROM review WHERE entity_type='ресторан' AND entity_id=NEW.restaurant_id;
    END IF;
    IF NEW.rating IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION 'Рейтинг берётся из отзывов. Если отзывов нет, укажите NULL' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$fn$;
CREATE TRIGGER product_rating_guard BEFORE INSERT OR UPDATE ON product FOR EACH ROW EXECUTE FUNCTION validate_aggregate_rating();
CREATE TRIGGER restaurant_rating_guard BEFORE INSERT OR UPDATE ON restaurant FOR EACH ROW EXECUTE FUNCTION validate_aggregate_rating();

CREATE FUNCTION recalculate_rating(p_type review_entity_type, p_id uuid) RETURNS void
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
BEGIN
    IF p_type = 'блюдо' THEN
        PERFORM 1 FROM product WHERE product_id = p_id FOR UPDATE;
        UPDATE product SET rating = (SELECT avg(rating) FROM review WHERE entity_type = p_type AND entity_id = p_id) WHERE product_id = p_id;
    ELSIF p_type = 'ресторан' THEN
        PERFORM 1 FROM restaurant WHERE restaurant_id = p_id FOR UPDATE;
        UPDATE restaurant SET rating = (SELECT avg(rating) FROM review WHERE entity_type = p_type AND entity_id = p_id) WHERE restaurant_id = p_id;
    END IF;
END;
$fn$;
CREATE FUNCTION rating_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
BEGIN
    IF TG_OP <> 'INSERT' THEN PERFORM recalculate_rating(OLD.entity_type, OLD.entity_id); END IF;
    IF TG_OP <> 'DELETE' THEN
        IF TG_OP = 'INSERT' THEN
            PERFORM recalculate_rating(NEW.entity_type, NEW.entity_id);
        ELSIF (NEW.entity_type, NEW.entity_id) IS DISTINCT FROM (OLD.entity_type, OLD.entity_id) THEN
            PERFORM recalculate_rating(NEW.entity_type, NEW.entity_id);
        END IF;
    END IF;
    RETURN NULL;
END;
$fn$;
CREATE TRIGGER review_rating_change AFTER INSERT OR UPDATE OR DELETE ON review FOR EACH ROW EXECUTE FUNCTION rating_change();

CREATE FUNCTION prevent_product_restaurant_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = khromov_food, exts, pg_catalog AS $fn$
BEGIN
    IF EXISTS (SELECT 1 FROM order_structure s JOIN orders o USING(order_id)
               WHERE s.product_id = NEW.product_id AND o.restaurant_id <> NEW.restaurant_id) THEN
        RAISE EXCEPTION 'Изменение ресторана блюда нарушает существующий заказ' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$fn$;
CREATE TRIGGER product_restaurant_guard BEFORE UPDATE OF restaurant_id ON product FOR EACH ROW EXECUTE FUNCTION prevent_product_restaurant_change();
COMMIT;
