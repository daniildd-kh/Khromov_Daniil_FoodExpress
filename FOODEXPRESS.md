# FoodExpress. Практическая работа 2

Хромов Даниил Дмитриевич, 3 семестр

Проект содержит схему `khromov_food` для сервиса доставки еды, генератор учебных данных, обработку рейтингов, расчёт выплат курьерам и финансовый отчёт

| Файл | Назначение |
| --- | --- |
| `db/schema/10_schema.sql` | Схема, типы, таблицы, ограничения и индексы |
| `db/schema/20_integrity.sql` | Проверки состава заказа и оплаты, пересчёт рейтинга |
| `db/schema/30_reports.sql` | `get_statistic()`, `courier_salary()`, `how_much_money` |
| `db/schema/40_data.sql` | `insert_test_data()`, `erase_test_data()`, `add_product()` |
| `db/schema/grants.sql` | Учебная роль `inspector` и права |
| `db/foodexpress_khromov.backup` | Дамп структуры схемы в формате PostgreSQL Custom |
| `db/constraints.md` | Обоснование ограничений со ссылками на бизнес-правила |
| `db/tests.md` | Протокол прогона под `inspector` |

## Восстановление

1. Подготовить пустую учебную базу PostgreSQL 17 с `exts.uuid_generate_v4()`. В отдельной локальной базе расширение можно подготовить скриптом `tools/bootstrap_local.sql`
2. Восстановить `db/foodexpress_khromov.backup` через `pg_restore --no-owner --no-acl --exit-on-error` в подготовленную базу
3. Выполнить `db/schema/grants.sql` в этой базе. Затем подключиться под `inspector` и выполнить `db/tests.sql` через `psql` на пустой схеме

Для сборки из исходных файлов вместо восстановления применить четыре пронумерованных SQL-скрипта по порядку, затем `grants.sql`

## Повтор полного прогона

На Linux или macOS с установленным PostgreSQL 17 можно создать отдельный кластер, собрать новый дамп и сразу проверить восстановление. Из корня форка укажите новый рабочий каталог

```sh
python3 tools/run_isolated.py --run --work-dir /tmp/foodexpress-verification
```

Дамп и журналы нового прогона сохраняются в указанном каталоге. Тесты создают и очищают данные только в выделенной учебной схеме

[Требования преподавателя](https://github.com/NKhashchanov/total_designing_db_2026/blob/main/docs/acceptance.md) · [Протокол](db/tests.md) · [Ограничения](db/constraints.md)
