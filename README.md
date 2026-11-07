# Thợ Nhanh & Việc Nhanh

Web (GitHub Pages) + Supabase (Postgres, PostGIS, Auth, Storage). Android/iOS sau này dùng chung project Supabase này. Hiện miễn phí hoàn toàn.

## Cài đặt
1. Tạo project tại supabase.com. Vào SQL Editor, chạy lần lượt 4 file trong thư mục `supabase`: `schema.sql`, `002_free_ratings.sql`, `003_home_stats.sql`, `004_chat_roles.sql`.
2. Authentication > Providers > Email: BẬT Email, TẮT Confirm email. Đăng nhập bằng số điện thoại dùng email ảo `sđt@sdt.thonhanh.app`, không cần SMS nên không tốn phí.
3. Mở `web/config.js`, dán Project URL và anon key (Project Settings > API).
4. Đẩy code lên nhánh `main` của repo GitHub. Settings > Pages > Source chọn GitHub Actions.
5. Thêm `https://<user>.github.io/<repo>/` vào Authentication > URL Configuration.

## Quy trình
Khách đăng tin, thợ nhận (miễn phí, thấy SĐT khách), làm xong khách bấm hoàn thành và chấm 1 đến 5 sao. Điểm sao hiện cho khách khi thợ nhận việc và hiện trên hồ sơ thợ.

## Sau này tính tiền
Cột `credits` và bảng `credit_transactions` vẫn còn. Chỉ cần thêm lại bước trừ credit trong `unlock_job`.

## Chat và đổi chế độ
- Sau khi thợ nhận việc, hai bên nhắn tin riêng theo từng việc (realtime, có đếm tin chưa đọc).
- Mỗi tài khoản đổi qua lại chế độ Khách và Thợ ở Hồ sơ hoặc nút trên đầu trang.
- Thợ có thể trả việc nếu không làm được. Tin quá 7 ngày tự ẩn khỏi radar.
