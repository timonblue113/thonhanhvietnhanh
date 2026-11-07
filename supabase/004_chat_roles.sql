-- Bản 4: chat theo từng việc, đổi chế độ Khách/Thợ trên cùng một tài khoản, trả việc, tin hết hạn sau 7 ngày.
-- Chạy SAU 003. Chạy lại nhiều lần vẫn an toàn.

create table if not exists messages(
  id bigserial primary key,
  job_id uuid not null references jobs(id) on delete cascade,
  sender_id uuid not null references profiles(id),
  body text not null check (length(body) between 1 and 1000),
  created_at timestamptz default now());
create index if not exists messages_job on messages(job_id,id);
create table if not exists chat_reads(
  job_id uuid not null references jobs(id) on delete cascade,
  user_id uuid not null references profiles(id),
  last_read timestamptz not null default now(),
  primary key(job_id,user_id));

alter table messages enable row level security;
alter table chat_reads enable row level security;
drop policy if exists "chat participants read" on messages;
create policy "chat participants read" on messages for select using (
  exists(select 1 from jobs j where j.id=messages.job_id and (j.customer_id=auth.uid() or j.taken_by=auth.uid())));
revoke all on messages from anon; revoke insert,update,delete on messages from authenticated;
grant select on messages to authenticated;
revoke all on chat_reads from anon,authenticated;

do $$ begin alter publication supabase_realtime add table messages;
exception when duplicate_object then null; end $$;

create or replace function send_message(p_job uuid,p_body text) returns void language plpgsql security definer set search_path=public as $$
declare j jobs; b text:=trim(coalesce(p_body,''));
begin
  select * into j from jobs where id=p_job;
  if not found or (auth.uid() is distinct from j.customer_id and auth.uid() is distinct from j.taken_by) then raise exception 'Bạn không thuộc cuộc trò chuyện này'; end if;
  if j.status not in ('taken','done') then raise exception 'Chỉ nhắn tin được sau khi thợ nhận việc'; end if;
  if length(b)<1 or length(b)>1000 then raise exception 'Tin nhắn cần từ 1 đến 1000 ký tự'; end if;
  if (select count(*) from messages where sender_id=auth.uid() and created_at>now()-interval '1 minute')>=30 then raise exception 'Bạn nhắn quá nhanh, hãy đợi một chút'; end if;
  insert into messages(job_id,sender_id,body) values(p_job,auth.uid(),b);
end $$;

create or replace function mark_read(p_job uuid) returns void language sql security definer set search_path=public as $$
  insert into chat_reads(job_id,user_id,last_read)
  select p_job,auth.uid(),now() where exists(select 1 from jobs where id=p_job and (customer_id=auth.uid() or taken_by=auth.uid()))
  on conflict(job_id,user_id) do update set last_read=now() $$;

create or replace function unread_counts() returns table(job_id uuid,n int,is_customer boolean) language sql security definer set search_path=public as $$
  select m.job_id,count(*)::int,(j.customer_id=auth.uid())
  from messages m join jobs j on j.id=m.job_id
  left join chat_reads r on r.job_id=m.job_id and r.user_id=auth.uid()
  where (j.customer_id=auth.uid() or j.taken_by=auth.uid()) and m.sender_id<>auth.uid() and m.created_at>coalesce(r.last_read,'-infinity'::timestamptz)
  group by m.job_id,j.customer_id $$;

-- Đổi chế độ Khách/Thợ trên cùng tài khoản
create or replace function switch_role(p_role text) returns void language plpgsql security definer set search_path=public as $$
begin
  if p_role not in ('customer','worker') then raise exception 'Chế độ không hợp lệ'; end if;
  update profiles set role=p_role where id=auth.uid();
end $$;

-- Thợ trả việc nếu không làm được: tin mở lại, xóa chat cũ để thợ mới không đọc được
create or replace function release_job(p_job uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update jobs set status='open',taken_by=null where id=p_job and taken_by=auth.uid() and status='taken';
  if not found then raise exception 'Không thể trả việc này'; end if;
  delete from messages where job_id=p_job; delete from chat_reads where job_id=p_job;
end $$;

-- Không cho thợ nhận tin của chính mình
create or replace function unlock_job(p_job uuid) returns json language plpgsql security definer set search_path=public as $$
declare j jobs;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='worker') then raise exception 'Hãy chuyển sang chế độ Thợ để nhận việc'; end if;
  select * into j from jobs where id=p_job for update;
  if not found or j.status<>'open' then raise exception 'Việc đã có người nhận hoặc đã hủy'; end if;
  if j.customer_id=auth.uid() then raise exception 'Bạn không thể nhận tin do chính mình đăng'; end if;
  update jobs set status='taken',taken_by=auth.uid() where id=p_job;
  return get_job_contact(p_job);
end $$;

-- Ẩn tin của mình và tin quá 7 ngày khỏi radar
create or replace function jobs_nearby(p_lat float8,p_lng float8,p_radius_km float8 default 15)
returns table(id uuid,service_id int,title text,description text,image_url text,address text,distance_km float8,lat float8,lng float8,created_at timestamptz)
language sql security definer set search_path=public,extensions as $$
  select j.id,j.service_id,j.title,j.description,j.image_url,j.address,
    st_distance(j.location,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography)/1000,j.lat,j.lng,j.created_at
  from jobs j
  where j.status='open' and j.customer_id<>auth.uid() and j.created_at>now()-interval '7 days'
    and exists(select 1 from profiles where id=auth.uid() and role='worker')
    and st_dwithin(j.location,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography,least(p_radius_km,50)*1000)
  order by 7 limit 50 $$;

revoke execute on function send_message(uuid,text),mark_read(uuid),unread_counts(),switch_role(text),release_job(uuid) from public,anon;
grant execute on function send_message(uuid,text),mark_read(uuid),unread_counts(),switch_role(text),release_job(uuid) to authenticated;
