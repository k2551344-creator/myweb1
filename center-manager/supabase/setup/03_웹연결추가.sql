-- 기존 데이터 유지: 센터·상품·이미지 관리 API
begin;
create or replace function public.gym_save_center(payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare cid uuid := nullif(payload->>'id','')::uuid; actor uuid := auth.uid();
begin
 if actor is null then raise exception '로그인이 필요합니다.'; end if;
 if cid is null then
  if not exists(select 1 from public.center_admins where user_id=actor and role='owner') then raise exception '센터 생성 권한이 없습니다.'; end if;
  insert into public.centers(name,brand,address,phone,active) values(payload->>'name',payload->>'brand',coalesce(payload->>'address',''),coalesce(payload->>'phone',''),coalesce((payload->>'active')::boolean,true)) returning id into cid;
  insert into public.center_admins(center_id,user_id,role) values(cid,actor,'owner');
 else
  if not gym_private.can_manage_center(cid) then raise exception '센터 관리 권한이 없습니다.'; end if;
  perform 1 from public.centers where id=cid for update;
  update public.centers set name=payload->>'name',brand=payload->>'brand',address=coalesce(payload->>'address',''),phone=coalesce(payload->>'phone',''),active=coalesce((payload->>'active')::boolean,true) where id=cid;
 end if;
 insert into public.center_appearance(center_id,background_color,background_image_id,headline,image_overlay)
 values(cid,coalesce(payload->>'bgColor','#102e2b'),nullif(payload->>'imageId','')::uuid,coalesce(payload->>'headline','오늘도, 나를 넘어서.'),coalesce((payload->>'overlay')::integer,40))
 on conflict(center_id) do update set background_color=excluded.background_color,background_image_id=excluded.background_image_id,headline=excluded.headline,image_overlay=excluded.image_overlay;
 return cid;
end $$;
create or replace function public.gym_save_product(payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare cid uuid := (payload->>'centerId')::uuid; pid uuid := nullif(payload->>'id','')::uuid; old_price bigint; old_interval integer; new_interval integer; target uuid;
begin
 if auth.uid() is null or not gym_private.can_manage_center(cid) then raise exception '상품 관리 권한이 없습니다.'; end if;
 -- Serialize catalog writes for this center, including price history.
 perform 1 from public.centers where id=cid for update;
 if pid is not null and not exists(select 1 from public.products where id=pid and center_id=cid) then raise exception '해당 센터의 상품이 아닙니다.'; end if;
 if jsonb_typeof(payload->'accessCenters') is distinct from 'array' or jsonb_array_length(payload->'accessCenters')=0 then raise exception '이용 가능 센터를 선택해 주세요.'; end if;
 for target in select value::uuid from jsonb_array_elements_text(payload->'accessCenters') loop
  if not gym_private.can_manage_center(target) then raise exception '이용 센터 관리 권한이 없습니다.'; end if;
 end loop;
 if pid is null then
  insert into public.products(center_id,name) values(cid,payload->>'name') returning id into pid;
 end if;
 update public.products set name=payload->>'name',description=coalesce(payload->>'description',''),category=payload->>'category',recurring=(payload->>'recurring')::boolean,
 weekly_limit=(payload->>'weeklyLimit')::integer,capacity=(payload->>'capacity')::integer,stock=(payload->>'stock')::integer,
 active=(payload->>'active')::boolean,selling=(payload->>'selling')::boolean,sort_order=(payload->>'sort')::integer,image_id=nullif(payload->>'imageId','')::uuid where id=pid;
 select amount,interval_months into old_price,old_interval from public.product_prices where product_id=pid order by effective_at desc,id desc limit 1;
 new_interval := case when (payload->>'recurring')::boolean then 1 else null end;
 if old_price is distinct from (payload->>'price')::bigint or old_interval is distinct from new_interval then
  insert into public.product_prices(product_id,amount,interval_months,created_by) values(pid,(payload->>'price')::bigint,new_interval,auth.uid());
 end if;
 delete from public.product_access_centers where product_id=pid;
 insert into public.product_access_centers(product_id,center_id) select distinct pid,value::uuid from jsonb_array_elements_text(payload->'accessCenters');
 return pid;
end $$;
create or replace function public.gym_register_media(payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare cid uuid := (payload->>'centerId')::uuid; mid uuid := (payload->>'id')::uuid;
begin
 if auth.uid() is null or not gym_private.can_manage_center(cid) then raise exception '이미지 관리 권한이 없습니다.'; end if;
 if not exists(select 1 from storage.objects where bucket_id='center-media' and name=payload->>'path') then raise exception '업로드한 이미지를 찾을 수 없습니다.'; end if;
 insert into public.media_assets(id,center_id,object_path,mime_type,byte_size,created_by)
 values(mid,cid,payload->>'path',payload->>'type',(payload->>'size')::bigint,auth.uid());
 return mid;
end $$;
-- Image metadata for visible catalog items only; no private member data.
create or replace function public.gym_catalog_media() returns table(id uuid,object_path text)
language sql stable security definer set search_path='' as $$
 select m.id,m.object_path from public.media_assets m where gym_private.can_read_media(m.object_path);
$$;
revoke all on function public.gym_save_center(jsonb),public.gym_save_product(jsonb),public.gym_register_media(jsonb),public.gym_catalog_media() from public,anon,authenticated;
grant execute on function public.gym_save_center(jsonb),public.gym_save_product(jsonb),public.gym_register_media(jsonb) to authenticated;
grant execute on function public.gym_catalog_media() to anon,authenticated;
notify pgrst, 'reload schema';
commit;
select 'CATALOG_API_READY' as result;
