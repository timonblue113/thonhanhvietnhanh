-- Số liệu hiển thị trang chủ: thợ đã đăng ký, việc đang chờ, theo từng dịch vụ
create or replace function home_stats() returns json language sql security definer set search_path=public as $$
  select json_build_object(
    'workers',(select count(*) from profiles where role='worker'),
    'open',(select count(*) from jobs where status='open'),
    'done',(select count(*) from jobs where status='done'),
    'by',coalesce((select json_object_agg(service_id,c) from (select service_id,count(*) c from jobs where status='open' group by 1) t),'{}'::json)) $$;
revoke execute on function home_stats() from public,anon;
grant execute on function home_stats() to authenticated;
