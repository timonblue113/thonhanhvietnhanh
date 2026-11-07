-- Bản 2: miễn phí (không trừ credit), đánh giá sao, hủy/hoàn thành việc.
-- Chạy SAU schema.sql trong Supabase > SQL Editor. Chạy lại nhiều lần vẫn an toàn.

create table if not exists reviews(
  id bigserial primary key,
  job_id uuid unique not null references jobs(id),
  customer_id uuid not null references profiles(id),
  worker_id uuid not null references profiles(id),
  stars int not null check (stars between 1 and 5),
  comment text default '', created_at timestamptz default now());
create index if not exists reviews_worker on reviews(worker_id);
alter table reviews enable row level security;
drop policy if exists "own reviews" on reviews;
create policy "own reviews" on reviews for select using (customer_id=auth.uid() or worker_id=auth.uid());
revoke insert,update,delete on reviews from anon,authenticated;

drop function if exists demo_topup();

create or replace function worker_stats(p_worker uuid) returns json language sql security definer set search_path=public as $$
  select json_build_object('avg',coalesce(round(avg(stars)::numeric,1),0),'cnt',count(*)) from reviews where worker_id=p_worker $$;

create or replace function create_job(p_service int,p_title text,p_desc text,p_image text,p_lat float8,p_lng float8,p_address text default null)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare v uuid;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='customer') then raise exception 'Chỉ khách hàng mới đăng việc'; end if;
  if length(trim(coalesce(p_title,'')))<3 or length(p_title)>120 then raise exception 'Tiêu đề cần từ 3 đến 120 ký tự'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Vị trí không hợp lệ'; end if;
  if (select count(*) from jobs where customer_id=auth.uid() and status='open')>=5 then raise exception 'Bạn đang có 5 tin chờ thợ. Hãy hủy hoặc chờ thợ nhận trước khi đăng thêm'; end if;
  insert into jobs(customer_id,service_id,title,description,image_url,address,lat,lng,location)
  values(auth.uid(),p_service,trim(p_title),left(coalesce(p_desc,''),1000),p_image,left(p_address,200),p_lat,p_lng,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography)
  returning id into v;
  return v;
end $$;

drop function if exists jobs_nearby(float8,float8,float8);
create or replace function jobs_nearby(p_lat float8,p_lng float8,p_radius_km float8 default 15)
returns table(id uuid,service_id int,title text,description text,image_url text,address text,distance_km float8,lat float8,lng float8,created_at timestamptz)
language sql security definer set search_path=public,extensions as $$
  select j.id,j.service_id,j.title,j.description,j.image_url,j.address,
    st_distance(j.location,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography)/1000,j.lat,j.lng,j.created_at
  from jobs j
  where j.status='open' and exists(select 1 from profiles where id=auth.uid() and role='worker')
    and st_dwithin(j.location,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography,least(p_radius_km,50)*1000)
  order by 7 limit 50 $$;

create or replace function get_job_contact(p_job uuid) returns json language plpgsql security definer set search_path=public as $$
declare j jobs; r json;
begin
  select * into j from jobs where id=p_job and status in ('taken','done');
  if not found then return null; end if;
  if auth.uid()=j.taken_by then
    select json_build_object('full_name',full_name,'phone',phone) into r from profiles where id=j.customer_id;
  elsif auth.uid()=j.customer_id then
    select json_build_object('full_name',p.full_name,'phone',p.phone,'rating',worker_stats(p.id)) into r from profiles p where p.id=j.taken_by;
  end if;
  return r;
end $$;

-- Nhận việc miễn phí, vẫn khóa dòng để hai thợ không nhận trùng
create or replace function unlock_job(p_job uuid) returns json language plpgsql security definer set search_path=public as $$
declare j jobs;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='worker') then raise exception 'Chỉ thợ mới nhận việc'; end if;
  select * into j from jobs where id=p_job for update;
  if not found or j.status<>'open' then raise exception 'Việc đã có người nhận hoặc đã hủy'; end if;
  update jobs set status='taken',taken_by=auth.uid() where id=p_job;
  return get_job_contact(p_job);
end $$;

create or replace function complete_job(p_job uuid,p_stars int,p_comment text default '') returns void language plpgsql security definer set search_path=public as $$
declare j jobs;
begin
  select * into j from jobs where id=p_job for update;
  if not found or j.customer_id<>auth.uid() then raise exception 'Không tìm thấy việc'; end if;
  if j.status<>'taken' then raise exception 'Việc chưa có thợ nhận hoặc đã hoàn thành'; end if;
  if p_stars not between 1 and 5 then raise exception 'Số sao không hợp lệ'; end if;
  insert into reviews(job_id,customer_id,worker_id,stars,comment) values(p_job,auth.uid(),j.taken_by,p_stars,left(coalesce(p_comment,''),500));
  update jobs set status='done' where id=p_job;
end $$;

create or replace function cancel_job(p_job uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update jobs set status='cancelled' where id=p_job and customer_id=auth.uid() and status='open';
  if not found then raise exception 'Không thể hủy tin này'; end if;
end $$;

revoke execute on function worker_stats(uuid),complete_job(uuid,int,text),cancel_job(uuid),unlock_job(uuid),get_job_contact(uuid),create_job(int,text,text,text,float8,float8,text),jobs_nearby(float8,float8,float8) from public,anon;
grant execute on function worker_stats(uuid),complete_job(uuid,int,text),cancel_job(uuid),unlock_job(uuid),get_job_contact(uuid),create_job(int,text,text,text,float8,float8,text),jobs_nearby(float8,float8,float8) to authenticated;
