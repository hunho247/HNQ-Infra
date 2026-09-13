# Nếu không liên lạc được với người vận hành

> Trang này viết cho người **không** biết Kubernetes. Đọc hết mất 3 phút.
> Đọc trước một lần lúc bình thường — lúc cần thì không còn thời gian đọc.
>
> ⚠️ Mọi chỗ `<...>` phải điền giá trị thật rồi mới có tác dụng. Trang chưa
> điền là trang vô dụng.

## Hệ thống này là gì

Ba máy tính chạy các website khám bệnh cho khách hàng:

| Máy | Ở đâu | Vai trò |
|---|---|---|
| `hnq-01` | VPS thuê của `<nhà cung cấp>`, tài khoản `<email>` | Điều phối. **Máy này chết thì website VẪN CHẠY.** |
| `hnq-02` | `<địa chỉ nhà>` | Chạy website thật + **dữ liệu khách hàng** |
| `hnq-03` | `<địa chỉ nhà>` | Môi trường thử nghiệm + giám sát |

Website khách hàng đang dùng: `<liệt kê domain>`.

## ❌ Ba việc KHÔNG được làm

1. **Không tắt, không cài lại, không format hai máy ở nhà** (`hnq-02`,
   `hnq-03`). Dữ liệu khách hàng nằm trên đĩa của chúng. Có bản sao lưu, nhưng
   bản mới nhất có thể cũ tới 1 giờ.
2. **Không xoá VPS.** Nếu nhà cung cấp khoá vì chưa trả tiền: trả tiền, đừng
   tạo máy mới. Cách trả: `<mô tả>`.
3. **Không gõ lệnh theo hướng dẫn trên mạng.** Hệ thống này mô tả đầy đủ trong
   Git; người biết Kubernetes đọc là làm được. Gõ mò thì làm hỏng thêm.

## Website khách hàng không truy cập được — làm gì

**Bước 1.** Hai máy ở nhà còn điện và mạng không?

Đây là nguyên nhân phổ biến nhất: mất điện, rút nhầm dây mạng, modem treo.
Bật lại máy / cắm lại mạng là xong, không mất gì. Máy khởi động lại rồi tự
chạy tiếp, **không cần ai bấm gì thêm** — đợi khoảng 5 phút.

**Bước 2.** Vẫn không được → gọi người, theo đúng thứ tự này:

| # | Vai trò | Tên | Liên lạc |
|---|---|---|---|
| 1 | Người vận hành | `<tên>` | `<sđt / zalo>` |
| 2 | Người kỹ thuật dự phòng | `<tên>` | `<sđt>` |
| 3 | Người giữ chìa khoá (không cần biết kỹ thuật) | `<tên>` | `<sđt>` |

**Bước 3.** Không gọi được ai → đưa mục tiếp theo cho bất kỳ người nào biết
Kubernetes. Không cần biết hệ thống này từ trước.

## Đưa cho người kỹ thuật

```
github.com/hunho247/HNQ-Infra  →  docs/RECOVERY.md
```

Toàn bộ hạ tầng mô tả trong Git: cấu hình, quy trình phục hồi, thời gian dự
kiến cho từng loại sự cố. Bắt đầu ở mục **"60 giây đầu tiên"**.

Để dựng lại được, họ cần **recovery kit** — 4 món cất trong `<password
manager>`, mục `<tên mục>`:

1. Bản sao lưu trạng thái hệ thống (etcd snapshot)
2. Khoá để máy khác tham gia cụm (k3s token)
3. Khoá giải mã mật khẩu (sealing key)
4. Khoá giải mã dữ liệu nhạy cảm (`encryption-config.json`)

**Thiếu món 2 hoặc 4 thì phục hồi mất 3 giờ thay vì 45 phút.** Ai có
*emergency access* vào password manager: `<tên người>`.

## Nếu người vận hành không quay lại nữa

Hệ thống tự chạy được nhiều tuần không cần ai đụng vào. Việc cần làm, theo thứ
tự:

1. **Trả tiền VPS và tên miền đúng hạn** — `<nhà cung cấp>`, `<khoảng tiền>`,
   `<chu kỳ>`. Đây là thứ duy nhất mà không làm là hệ thống sẽ chết dù không ai
   đụng vào nó.
2. Giữ nguyên hai máy ở nhà: có điện, có mạng, đừng di chuyển.
3. Tìm người kỹ thuật và đưa họ mục ở trên. Bàn giao được trong một buổi.
4. Báo khách hàng `<danh sách khách hàng + liên lạc>` rằng có thay đổi người
   phụ trách.

---

*Ai đó ngoài người vận hành đã đọc trang này một lần chưa?*
`<tên người>`, ngày `<...>`. — Trang chưa ai đọc là trang chưa chắc dùng được.
