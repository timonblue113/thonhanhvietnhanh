-- Thợ Nhanh & Việc Nhanh: schema dùng chung cho Web, Android, iOS
-- Chạy toàn bộ file này trong Supabase > SQL Editor
create extension if not exists postgis;

create table if not exists profiles(
  id uuid primary key references auth.users on delete cascade,
  role text not null default 'customer' check (role in ('customer','worker')),
  full_name text not null default '', phone text not null default '',
  credits int not null default 0 check (credits >= 0),
  created_at timestamptz default now());

create table if not exists services(id serial primary key, slug text unique not null, name text not null, icon text);
insert into services(slug,name,icon) values
 ('camera','Camera','📹'),('mang','Mạng, Wi-Fi','📶'),('lanh','Điện lạnh','❄️'),
 ('may','Máy tính','💻'),('dien','Điện nước','💡'),('khoa','Khóa','🔑') on conflict do nothing;

create table if not exists jobs(
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references profiles(id),
  service_id int not null references services(id),
  title text not null, description text default '', image_url text, address text,
  lat float8 not null, lng float8 not null, location geography(point,4326) not null,
  status text not null default 'open' check (status in ('open','taken','done','cancelled')),
  taken_by uuid references profiles(id), created_at timestamptz default now());
create index if not exists jobs_geo on jobs using gist(location);
create index if not exists jobs_status on jobs(status);

create table if not exists credit_transactions(
  id bigserial primary key, user_id uuid not null references profiles(id),
  amount int not null, reason text not null, job_id uuid references jobs(id), created_at timestamptz default now());

-- Tự tạo profile khi đăng ký (role lấy từ metadata)
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,role,full_name,phone,credits) values(new.id,
    case when new.raw_user_meta_data->>'role'='worker' then 'worker' else 'customer' end,
    coalesce(new.raw_user_meta_data->>'full_name',''), coalesce(new.raw_user_meta_data->>'phone',''),
    case when new.raw_user_meta_data->>'role'='worker' then 5 else 0 end);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- RLS
alter table profiles enable row level security;
alter table services enable row level security;
alter table jobs enable row level security;
alter table credit_transactions enable row level security;
create policy "own profile" on profiles for select using (id=auth.uid());
create policy "read services" on services for select using (true);
create policy "own jobs" on jobs for select using (customer_id=auth.uid() or taken_by=auth.uid());
create policy "own credit log" on credit_transactions for select using (user_id=auth.uid());
revoke insert,update,delete on jobs,profiles,credit_transactions,services from anon,authenticated;
grant update(full_name,phone) on profiles to authenticated;
create policy "edit own profile" on profiles for update using (id=auth.uid());

-- RPC: khách đăng việc
create or replace function create_job(p_service int,p_title text,p_desc text,p_image text,p_lat float8,p_lng float8,p_address text default null)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare v uuid;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='customer') then raise exception 'Chỉ khách hàng mới đăng việc'; end if;
  insert into jobs(customer_id,service_id,title,description,image_url,address,lat,lng,location)
  values(auth.uid(),p_service,p_title,p_desc,p_image,p_address,p_lat,p_lng,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography)
  returning id into v;
  return v;
end $$;

-- RPC: thợ tìm việc quanh vị trí (không lộ số điện thoại khách)
create or replace function jobs_nearby(p_lat float8,p_lng float8,p_radius_km float8 default 15)
returns table(id uuid,service_id int,title text,description text,image_url text,distance_km float8,lat float8,lng float8,created_at timestamptz)
language sql security definer set search_path=public,extensions as $$
  select j.id,j.service_id,j.title,j.description,j.image_url,
    st_distance(j.location,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography)/1000, j.lat,j.lng,j.created_at
  from jobs j
  where j.status='open' and exists(select 1 from profiles where id=auth.uid() and role='worker')
    and st_dwithin(j.location,st_setsrid(st_makepoint(p_lng,p_lat),4326)::geography,p_radius_km*1000)
  order by 6 limit 50 $$;

-- RPC: liên hệ của bên còn lại (chỉ sau khi việc đã được nhận)
create or replace function get_job_contact(p_job uuid) returns json language plpgsql security definer set search_path=public as $$
declare j jobs; r json;
begin
  select * into j from jobs where id=p_job and status<>'open';
  if not found then return null; end if;
  if auth.uid()=j.taken_by then select json_build_object('full_name',full_name,'phone',phone) into r from profiles where id=j.customer_id;
  elsif auth.uid()=j.customer_id then select json_build_object('full_name',full_name,'phone',phone) into r from profiles where id=j.taken_by; end if;
  return r;
end $$;

-- RPC: thợ nhận việc, trừ 1 credit, khóa dòng để tránh 2 thợ nhận cùng lúc
create or replace function unlock_job(p_job uuid) returns json language plpgsql security definer set search_path=public as $$
declare j jobs; c int;
begin
  select * into j from jobs where id=p_job for update;
  if not found or j.status<>'open' then raise exception 'Việc đã có người nhận'; end if;
  select credits into c from profiles where id=auth.uid() and role='worker' for update;
  if c is null then raise exception 'Chỉ thợ mới nhận việc'; end if;
  if c<1 then raise exception 'Hết credit, hãy nạp thêm'; end if;
  update profiles set credits=credits-1 where id=auth.uid();
  insert into credit_transactions(user_id,amount,reason,job_id) values(auth.uid(),-1,'unlock_job',p_job);
  update jobs set status='taken',taken_by=auth.uid() where id=p_job;
  return get_job_contact(p_job);
end $$;

-- DEMO: nạp credit giả lập. XÓA hàm này khi có thanh toán thật.
create or replace function demo_topup() returns void language sql security definer set search_path=public as $$
  with u as (update profiles set credits=credits+5 where id=auth.uid() and role='worker' returning id)
  insert into credit_transactions(user_id,amount,reason) select id,5,'demo_topup' from u $$;

revoke execute on all functions in schema public from anon;

-- Storage ảnh lỗi
insert into storage.buckets(id,name,public) values('job-images','job-images',true) on conflict do nothing;
create policy "upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id='job-images' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "read job images" on storage.objects for select using (bucket_id='job-images');
