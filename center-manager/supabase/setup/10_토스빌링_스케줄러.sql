-- Run after 09 and Edge Function deployment. No API keys belong in this file.
-- Create Vault secrets gym_billing_function_url and gym_billing_cron_secret in the Dashboard first.
begin;
create extension if not exists pg_cron;
create extension if not exists pg_net;
-- pg_net temporarily holds decrypted HTTP headers. Do not expose its queue to browser roles.
revoke all on net.http_request_queue,net._http_response from public,anon,authenticated;
do $$ begin
 if has_table_privilege('anon','net.http_request_queue','SELECT') or has_table_privilege('authenticated','net.http_request_queue','SELECT') then
  raise exception 'pg_net 요청 큐 접근 권한을 먼저 제한해 주세요.';
 end if;
 if not exists(select 1 from vault.decrypted_secrets where name='gym_billing_function_url' and decrypted_secret ~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/gym-payments$') then raise exception 'Vault에 gym_billing_function_url을 등록해 주세요.';end if;
 if not exists(select 1 from vault.decrypted_secrets where name='gym_billing_cron_secret' and length(decrypted_secret)>=32) then raise exception 'Vault에 32자 이상의 gym_billing_cron_secret을 등록해 주세요.';end if;
end $$;
create or replace function gym_private.run_billing_cron() returns bigint language sql security definer set search_path='' as $$
 select net.http_post(
 url:=(select decrypted_secret from vault.decrypted_secrets where name='gym_billing_function_url'),
 headers:=jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='gym_billing_cron_secret')),
 body:='{"action":"renew"}'::jsonb,timeout_milliseconds:=120000
 );
$$;
revoke all on function gym_private.run_billing_cron() from public,anon,authenticated,service_role;
-- A stable job name updates the existing job instead of creating duplicate schedules.
select cron.schedule('cherryboxing-test-billing','*/5 * * * *','select gym_private.run_billing_cron();');
commit;
select 'BILLING_CRON_READY' as result;
