-- Роль для postgres_exporter (sidecar в поде БД, см. манифесты ДЗ №4).
-- Встроенная роль pg_monitor даёт чтение статистики (pg_stat_*, pg_settings,
-- размеры БД) и не даёт доступа к данным приложения — экспортеру не нужен
-- суперпользователь. Пароль не задаём: экспортер подключается с 127.0.0.1
-- внутри пода, а такие подключения pg_hba образа postgres пропускает (trust);
-- снаружи пода роль без пароля войти не может (scram-sha-256).
-- Роль — объект всего кластера PostgreSQL, поэтому создаём её, только если
-- её ещё нет (например, она уже заведена миграцией другой базы).
--
-- Мониторинг не должен ронять приложение: если у пользователя миграций нет
-- права создавать роли (управляемая БД, пользователь без CREATEROLE), миграция
-- не падает, а пишет предупреждение в лог PostgreSQL. Роль тогда заводит
-- администратор БД теми же двумя командами, а экспортер до этого отдаёт pg_up = 0.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
        CREATE ROLE postgres_exporter LOGIN;
    END IF;
    GRANT pg_monitor TO postgres_exporter;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE WARNING 'postgres_exporter role not created: %', SQLERRM;
END
$$;
