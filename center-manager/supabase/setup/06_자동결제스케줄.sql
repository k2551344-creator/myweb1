-- Edge Function과 서버 Secrets 설정 후 실행하세요.
-- Supabase Vault에 gym_cron_secret을 먼저 등록합니다.
-- 값은 Edge Function CRON_SECRET과 같아야 합니다. SQL/깃허브에 실제 값을 쓰지 마세요.
begin;
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$ begin
 if not exists(select 1 from vault.decrypted_secrets where name='gym_cron_secret') then raise exception 'Vault에 gym_cron_secret을 먼저 등록하세요.'; end if;
end $$;
select cron.schedule('gym-renew-memberships','*/5 * * * *',
$job$
 select net.http_post(
  url:='https://neswgimmvxzhqtnoaslu.supabase.co/functions/v1/gym-payments',
  headers:=jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='gym_cron_secret' limit 1)),
  body:='{"action":"renew"}'::jsonb,
  timeout_milliseconds:=120000
 );
$job$);
commit;
select 'BILLING_SCHEDULE_READY' as result;
