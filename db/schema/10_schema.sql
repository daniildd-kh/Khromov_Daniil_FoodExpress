-- Хромов Даниил Дмитриевич, FOOD-101
BEGIN;
CREATE SCHEMA khromov_food;
SET LOCAL search_path = khromov_food, exts, pg_catalog;

CREATE TYPE restaurant_status AS ENUM ('активен', 'неактивен');
CREATE TYPE product_status AS ENUM ('доступно', 'нет_в_наличии', 'архив');
CREATE TYPE courier_status AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');
CREATE TYPE order_status AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');
CREATE TYPE order_pay_status AS ENUM ('ожидает', 'оплачен', 'ошибка');
CREATE TYPE payment_status AS ENUM ('успех', 'ошибка', 'в_обработке');
CREATE TYPE payment_type AS ENUM ('карта', 'наличные', 'безнал');
CREATE TYPE review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');

CREATE TABLE client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(64) NOT NULL UNIQUE CHECK (length(btrim(login)) > 0),
    password varchar(32) NOT NULL CHECK (password ~ '^[0-9a-f]{32}$'),
    phone_number varchar(24) NOT NULL UNIQUE CHECK (length(btrim(phone_number)) > 0)
);
CREATE TABLE address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(100) NOT NULL CHECK (length(btrim(street)) > 0),
    house_number varchar(20) NOT NULL CHECK (length(btrim(house_number)) > 0),
    apartment_office varchar(20) CHECK (apartment_office IS NULL OR length(btrim(apartment_office)) > 0),
    CONSTRAINT address_physical_unique UNIQUE NULLS NOT DISTINCT (street, house_number, apartment_office)
);
CREATE TABLE client_address (
    client_id uuid NOT NULL REFERENCES client(client_id),
    address_id uuid NOT NULL REFERENCES address(address_id),
    PRIMARY KEY (client_id, address_id)
);
CREATE TABLE restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(100) NOT NULL CHECK (length(btrim(restaurant_name)) > 0),
    address_id uuid NOT NULL UNIQUE REFERENCES address(address_id),
    description text NOT NULL CHECK (length(btrim(description)) > 0),
    work_start time NOT NULL,
    work_end time NOT NULL,
    company_details text NOT NULL CHECK (length(btrim(company_details)) > 0),
    rating numeric(6,4) CHECK (rating BETWEEN 0 AND 5),
    status restaurant_status NOT NULL,
    CONSTRAINT restaurant_work_time CHECK (work_end > work_start)
);
CREATE TABLE courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    fio varchar(150) NOT NULL CHECK (length(btrim(fio)) > 0),
    phone_number varchar(24) NOT NULL CHECK (length(btrim(phone_number)) > 0),
    status courier_status NOT NULL,
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric(2,1) NOT NULL DEFAULT 0.1 CHECK (coefficient BETWEEN 0.1 AND 0.5),
    CONSTRAINT courier_dismissal_required CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL),
    CONSTRAINT courier_employment_dates CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date)
);
CREATE TABLE courier_pay (
    year integer NOT NULL CHECK (year > 0),
    month integer NOT NULL CHECK (month BETWEEN 1 AND 12),
    courier_id uuid NOT NULL REFERENCES courier(courier_id),
    amount numeric(16,2) NOT NULL CHECK (amount >= 0),
    coefficient_used numeric(2,1) NOT NULL CHECK (coefficient_used BETWEEN 0.1 AND 0.5),
    PRIMARY KEY (year, month, courier_id)
);
CREATE TABLE product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(100) NOT NULL CHECK (length(btrim(product_category_name)) > 0)
);
CREATE TABLE product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(100) NOT NULL CHECK (length(btrim(product_name)) > 0),
    product_category_id uuid NOT NULL REFERENCES product_category(product_category_id),
    price numeric(12,2) NOT NULL CHECK (price >= 0),
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id),
    photo_url text,
    rating numeric(6,4) CHECK (rating BETWEEN 0 AND 5),
    status product_status NOT NULL,
    description text NOT NULL CHECK (length(btrim(description)) > 0)
);
CREATE TABLE orders (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES courier(courier_id),
    client_id uuid NOT NULL REFERENCES client(client_id),
    address_id uuid NOT NULL REFERENCES address(address_id),
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id),
    order_timestamp timestamptz NOT NULL,
    delivery_timestamp timestamptz,
    order_amount numeric(14,2) NOT NULL CHECK (order_amount >= 0),
    commission numeric(14,2) GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED NOT NULL,
    total_amount numeric(14,2) GENERATED ALWAYS AS (order_amount + round(order_amount * 0.10, 2)) STORED NOT NULL,
    status order_status NOT NULL,
    pay_status order_pay_status NOT NULL DEFAULT 'ожидает',
    description text NOT NULL,
    CONSTRAINT order_total_minimum CHECK (total_amount >= 1000),
    CONSTRAINT order_delivery_dates CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    CONSTRAINT order_delivered_time_required CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL),
    CONSTRAINT order_client_address_fk FOREIGN KEY (client_id, address_id) REFERENCES client_address(client_id, address_id),
    CONSTRAINT order_owner_reference UNIQUE (order_id, client_id)
);
CREATE TABLE payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL REFERENCES orders(order_id),
    payment_type payment_type NOT NULL,
    payment_amount numeric(14,2) NOT NULL CHECK (payment_amount >= 0),
    transaction_id varchar(128) NOT NULL UNIQUE CHECK (length(btrim(transaction_id)) > 0),
    payment_timestamp timestamptz NOT NULL,
    status payment_status NOT NULL
);
CREATE UNIQUE INDEX payment_one_success ON payment(order_id) WHERE status = 'успех';
CREATE TABLE order_structure (
    order_id uuid NOT NULL REFERENCES orders(order_id),
    product_id uuid NOT NULL REFERENCES product(product_id),
    quantity numeric(12,3) NOT NULL CHECK (quantity > 0),
    unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, product_id)
);
CREATE TABLE review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    client_id uuid NOT NULL REFERENCES client(client_id),
    review_timestamp timestamptz NOT NULL,
    entity_id uuid NOT NULL,
    entity_type review_entity_type NOT NULL,
    order_id uuid NOT NULL REFERENCES orders(order_id),
    description text NOT NULL CHECK (length(btrim(description)) > 0),
    photo_url text,
    rating numeric(2,1) NOT NULL CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT review_one_per_target UNIQUE (order_id, entity_type, entity_id),
    CONSTRAINT review_order_owner_fk FOREIGN KEY (order_id, client_id) REFERENCES orders(order_id, client_id)
);

CREATE INDEX orders_restaurant_delivered_idx ON orders(restaurant_id) WHERE status = 'доставлен';
CREATE INDEX orders_courier_delivery_idx ON orders(courier_id, delivery_timestamp) WHERE status = 'доставлен';
CREATE INDEX review_target_idx ON review(entity_type, entity_id);
CREATE INDEX product_restaurant_idx ON product(restaurant_id);
COMMIT;
