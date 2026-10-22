# GitHub App cho ARC runner (`vn-gaqc-docker`)

Actions Runner Controller (ARC) trong cụm k3s dùng một GitHub App để đăng ký và quản lý self-hosted runner của org. Tài liệu này mô tả App cần tạo, các giá trị cần lấy, và cách dùng chúng trong project này. Các bước dựng cụm nằm trong [proxmox-k3s-arc-guide.md](proxmox-k3s-arc-guide.md); file này thay cho bước 5.1 và 5.3 ở đó.

## Dùng App có sẵn `gravityactionvn`

Org `Gravity-Global` đã có App [`gravityactionvn`](https://github.com/organizations/Gravity-Global/settings/apps/gravityactionvn), nên **không cần tạo App mới**. Cần lấy đủ 3 giá trị:

| Giá trị | Lấy ở đâu | Có thay đổi gì App không |
| --- | --- | --- |
| App ID | **`1192728`**, lấy từ trang [General của App](https://github.com/organizations/Gravity-Global/settings/apps/gravityactionvn). ARC dùng App ID, không dùng Client ID | Không, chỉ đọc |
| Installation ID | **`63354448`**, lấy từ [trang installation](https://github.com/organizations/Gravity-Global/settings/installations/63354448) (Org → Settings → GitHub Apps → `gravityactionvn` → Configure) | Không, chỉ đọc |
| Private key | Mục **Private keys** của App → **Generate a private key** | **Thêm** một key mới. Không đụng tới key cũ hay Client secret |

GitHub chỉ cho tải private key **một lần**, lúc key được tạo. Vì vậy, nếu không ai còn giữ file `.pem` cũ, cách duy nhất là tạo thêm key. Việc tạo key mới:

- **Không** vô hiệu hoá key đang có. Một App có thể có nhiều private key cùng lúc, và hệ thống nào đang dùng key cũ vẫn chạy bình thường.
- **Không** liên quan tới **Client secret**. Client secret dùng cho OAuth, ARC không dùng tới. Đừng bấm "Generate a new client secret".
- Để dễ quản lý, ghi lại 8 ký tự đầu của **SHA256 fingerprint** của key mới (hiện ngay dưới key trong danh sách). Key nào là của ARC thì sau này đổi hoặc xoá đúng key đó, không nhầm với key của hệ thống khác.

Kiểm tra trước khi dùng (chỉ xem, không sửa):

1. **Quyền:** tab **Permissions & events** phải có Organization permissions → `Self-hosted runners` = **Read and write**. Nếu chưa có, phải thêm quyền. Thêm quyền sẽ áp dụng cho mọi hệ thống đang dùng App này và cần Owner chấp nhận ở trang installation. Hãy báo người quản lý App trước khi đổi.
2. **Đã cài vào org:** Org → Settings → GitHub Apps phải có `gravityactionvn`. Repository access phải là All repositories, hoặc gồm đủ các repo dùng `vn-gaqc-docker`.
3. **Ai khác đang dùng App:** các runner LXC cũ rất có thể đăng ký qua chính App này. Nếu ai đó xoá key, đổi quyền hay gỡ App, runner ARC cũng sẽ dừng theo. Hãy cho người quản lý App biết ARC cũng dùng App này, kèm fingerprint của key ARC.

Trạng thái đã kiểm tra (2026-10-22): App có `Self-hosted runners` = **Read and write**, Repository access là **All repositories**. ARC dùng được ngay.

### Rủi ro khi dùng App này

`gravityactionvn` có quyền rộng hơn ARC cần rất nhiều: Read and write tới code, administration, workflows, pull requests, packages, checks, issues, và đọc secrets. Tất cả áp dụng trên **mọi repo** của org. Private key đặt trong cụm mang theo toàn bộ các quyền đó.

- Guide đã đặt controller và listener (hai pod đọc secret chứa key) chạy trên `k3s-server-1`. Runner pod chạy privileged chỉ nằm trên worker, nên job không đọc được key qua node.
- Cách an toàn nhất là **tạo App riêng chỉ có `Self-hosted runners`** theo phần "Thông số App" bên dưới, rồi thay App ID, Installation ID và key trong secret. Phần cấu hình còn lại của cụm giữ nguyên.

Phần "Thông số App" bên dưới dùng để đối chiếu cấu hình, hoặc khi tạo App riêng.

## Vì sao dùng GitHub App thay cho PAT

| | GitHub App | Personal Access Token |
| --- | --- | --- |
| Thuộc về | Org | Một người dùng; người đó rời org thì token mất hiệu lực |
| Hết hạn | Private key không hết hạn. ARC tự đổi key lấy installation token (sống khoảng 1 giờ) | Có ngày hết hạn, phải gia hạn bằng tay |
| Quyền | Chỉ `Self-hosted runners` | Classic PAT cần `admin:org` (toàn quyền admin org) |
| Rate limit | Riêng của App | Dùng chung với mọi việc khác của người dùng đó |

## Ai làm

Chỉ **Owner của org** mới tạo và cài được App. Nếu bạn không phải Owner, gửi phần "Thông số App" bên dưới cho Owner. Nhờ họ gửi lại 3 giá trị ở phần "Giá trị cần lấy" qua kênh an toàn, ví dụ password manager dùng chung. Không gửi qua chat hay email.

## Thông số App

Vào `https://github.com/organizations/Gravity-Global/settings/apps` → **New GitHub App**.

| Trường | Giá trị | Ghi chú |
| --- | --- | --- |
| GitHub App name | `gravityactionvn` (App có sẵn). Nếu tạo App riêng: `arc-vn-gaqc-docker` | Tên phải duy nhất trên toàn GitHub |
| Description | `ARC runner scale set vn-gaqc-docker trên Proxmox GG-Nha-VM-GA` | Để người khác biết App dùng vào việc gì |
| Homepage URL | URL của org hoặc của repo này | Bắt buộc phải có, không được dùng tới |
| Callback URL | Để trống | |
| Expire user authorization tokens | Để mặc định | Không áp dụng: ARC không dùng user token |
| Request user authorization (OAuth) during installation | **Bỏ tick** | |
| Enable Device Flow | **Bỏ tick** | |
| Setup URL | Để trống | |
| Webhook → Active | **Bỏ tick** | ARC long-poll GitHub, không cần webhook |
| Where can this GitHub App be installed? | **Only on this account** | |

### Quyền (Permissions)

Chỉ cấp đúng 2 quyền dưới đây, mọi quyền khác để **No access**.

| Nhóm | Quyền | Mức |
| --- | --- | --- |
| Organization permissions | **Self-hosted runners** | **Read and write** |
| Repository permissions | Metadata | Read-only (GitHub tự bật, không tắt được) |

**Subscribe to events:** để trống.

Chỉ khi đăng ký runner ở cấp **repo** (không phải org) mới cần thêm Repository permission `Administration` = Read and write. Project này đăng ký ở cấp org nên không cần quyền đó.

### Tạo và cài App

1. Bấm **Create GitHub App**.
2. Trên trang của App, ghi lại **App ID**. Đây là một dãy số, ví dụ `1234567`. Đừng nhầm với Client ID.
3. Kéo xuống mục **Private keys** → **Generate a private key**. Trình duyệt sẽ tải về file `<tên-app>.<ngày>.private-key.pem`.
4. Ở menu trái chọn **Install App**, bấm **Install** ở dòng org `Gravity-Global`:
   - **All repositories**: cách đơn giản nhất.
   - Hoặc **Only select repositories**: khi đó phải chọn **đủ mọi repo đang dùng `runs-on: vn-gaqc-docker`**.
5. Sau khi cài xong, URL trên trình duyệt có dạng `https://github.com/organizations/Gravity-Global/settings/installations/<INSTALLATION_ID>`. Ghi lại số ở cuối URL.

Repo nào được phép dùng runner thì quyết định ở **runner group** (bước 5.2 của guide), không phải ở chỗ chọn repo khi cài App.

## Giá trị cần lấy

| Giá trị | Ví dụ | Lấy ở đâu |
| --- | --- | --- |
| App ID | `1234567` | Trang General của App |
| Installation ID | `87654321` | Số cuối URL của trang installation |
| Private key | File `.pem` | Tải về ở mục Private keys |

Lưu cả 3 giá trị vào password manager. **Không** đưa file `.pem` vào repo, không ghi vào `k3s-plan.env`, và không dán vào issue hay chat. Ai có private key cùng App ID là đăng ký được runner vào org.

## Dùng trong project này

### 1. Tạo secret trong cụm (thay cho bước 5.3 của guide)

Các lệnh dưới đây chạy trên `k3s-server-1`. Từ Proxmox Shell, vào server bằng `ssh ubuntu@192.168.8.2`.

Chuyển private key lên server:

1. Mở file `.pem` trên máy bạn bằng một trình soạn thảo text.
2. Copy toàn bộ nội dung, kể cả dòng `-----BEGIN RSA PRIVATE KEY-----` và `-----END RSA PRIVATE KEY-----`.
3. Trên server, chạy `nano ~/arc-app.pem`, dán nội dung vào rồi lưu.

```bash
kubectl create namespace arc-systems
kubectl create namespace arc-runners

read -rp 'App ID: ' APP_ID
read -rp 'Installation ID: ' INSTALLATION_ID
kubectl create secret generic github-app -n arc-runners \
  --from-literal=github_app_id="$APP_ID" \
  --from-literal=github_app_installation_id="$INSTALLATION_ID" \
  --from-file=github_app_private_key="$HOME/arc-app.pem"

kubectl get secret github-app -n arc-runners -o jsonpath='{.data}' | jq 'keys'
# ["github_app_id","github_app_installation_id","github_app_private_key"]

shred -u ~/arc-app.pem
```

Sau đó xoá luôn file `.pem` trong thư mục Downloads trên máy bạn, vì bản gốc đã nằm trong password manager.

### 2. Trỏ scale set tới secret (bước 7 của guide)

Trong `~/runner-values.yaml`:

```yaml
githubConfigUrl: "https://github.com/Gravity-Global"
githubConfigSecret: github-app
```

Secret phải nằm cùng namespace với scale set, ở đây là `arc-runners`.

### 3. Kiểm tra

Sau khi `helm install vn-gaqc-docker` (bước 7):

```bash
kubectl get pods -n arc-systems | grep listener        # Running
kubectl logs -n arc-systems $(kubectl get pods -n arc-systems -o name | grep listener) | tail -20
```

Trên GitHub, mở Org → Settings → Actions → Runners. Scale set `vn-gaqc-docker` sẽ hiện ra với 0 runner. Trong trang App → **Advanced → Recent Deliveries** sẽ không có gì, vì App không dùng webhook. Như vậy là đúng.

## Cách App hoạt động trong cụm

1. ARC dùng private key ký một JWT (sống khoảng 10 phút) để chứng minh mình là App.
2. Dùng JWT đó đổi lấy **installation token** (sống khoảng 1 giờ) cho installation trong org.
3. Dùng installation token để đăng ký scale set, long-poll lấy job và tạo JIT config cho từng runner.
4. Gần hết giờ thì ARC tự lặp lại các bước trên. Bạn không phải làm gì.

JWT có thời gian phát hành và hết hạn, nên **đồng hồ của node phải đúng**. Guide đã cài `chrony` trên mọi VM ở bước 1–2. Nếu node lệch giờ, listener sẽ báo lỗi JWT (xem phần Xử lý lỗi).

## Bảo trì

### Đổi private key (khuyến nghị 1 lần mỗi năm, hoặc ngay khi nghi key bị lộ)

App có thể có nhiều private key cùng lúc, nên đổi key không làm gián đoạn runner.

1. Trang App → **Private keys** → **Generate a private key** để tải key mới.
2. Trên `k3s-server-1`, `nano ~/arc-app.pem` và dán key mới, rồi ghi đè secret:

    ```bash
    kubectl create secret generic github-app -n arc-runners \
      --from-literal=github_app_id="<APP_ID>" \
      --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
      --from-file=github_app_private_key="$HOME/arc-app.pem" \
      --dry-run=client -o yaml | kubectl apply -f -
    shred -u ~/arc-app.pem
    kubectl delete pod -n arc-systems $(kubectl get pods -n arc-systems -o name | grep listener | cut -d/ -f2)
    ```

3. Đợi listener chạy lại (`Running`) và chạy thử 1 job, rồi mới **Delete** key ARC cũ trên trang App. Đối chiếu fingerprint để không xoá nhầm key của hệ thống khác.
4. Cập nhật key mới vào password manager.

### Đổi quyền App

Khi thêm hoặc bớt quyền, GitHub sẽ yêu cầu Owner **chấp nhận quyền mới** ở trang installation của org (Org → Settings → GitHub Apps → `gravityactionvn` → Review request). App dùng chung với hệ thống khác, nên phải báo trước khi đổi quyền. Chưa chấp nhận thì App vẫn chạy với quyền cũ.

### Thu hồi khẩn cấp

Nếu private key bị lộ:

1. Trang App → **Private keys** → **Delete** đúng key đó (đối chiếu fingerprint). Key mất hiệu lực ngay, và ARC ngừng nhận job. Các key khác của App không bị ảnh hưởng.
2. Tạo key mới và làm theo mục "Đổi private key" ở trên.

Muốn tắt hẳn runner thì **Suspend** hoặc **Uninstall** App ở trang installation.

## Xử lý lỗi

Xem log listener: `kubectl logs -n arc-systems $(kubectl get pods -n arc-systems -o name | grep listener)`.

| Lỗi trong log listener | Nguyên nhân | Xử lý |
| --- | --- | --- |
| `401 Bad credentials`, `could not parse private key` | Sai App ID, hoặc file `.pem` thiếu dòng/sai định dạng khi dán | Kiểm tra App ID (là số, không phải Client ID); dán lại đủ cả dòng BEGIN/END rồi ghi đè secret |
| `404 Not Found` khi lấy installation token | Sai Installation ID, hoặc App chưa cài vào org | Mở lại trang installation để lấy đúng số; kiểm tra App đã được cài vào `Gravity-Global` |
| `403 Resource not accessible by integration` | App thiếu quyền `Self-hosted runners`, hoặc quyền mới chưa được Owner chấp nhận | Kiểm tra Permissions; chấp nhận request ở trang installation |
| `'Issued at' claim (iat) must be an Integer representing a time in the past`, `JWT ... expired` | Đồng hồ của node bị lệch | Trên node: `chronyc tracking`, `timedatectl`. Bật lại `chrony` |
| Listener chạy bình thường nhưng job vẫn "Waiting for a runner" | Không phải lỗi App: `runs-on` sai, hoặc repo không thuộc runner group | Xem guide, phần Theo dõi và xử lý sự cố |

## Checklist

- [ ] App `gravityactionvn` có quyền `Self-hosted runners` = Read and write
- [ ] App đã được cài vào org `Gravity-Global` (All repositories, hoặc đủ các repo dùng `vn-gaqc-docker`)
- [ ] Đã tạo private key riêng cho ARC và ghi lại fingerprint; App ID, Installation ID, private key đã lưu vào password manager
- [ ] Người quản lý App biết ARC đang dùng App này
- [ ] Secret `github-app` đã có trong namespace `arc-runners`; file `.pem` đã xoá khỏi server và máy cá nhân
- [ ] `runner-values.yaml` đặt `githubConfigSecret: github-app`; listener `Running`; scale set hiện trên GitHub
- [ ] Đã đặt lịch đổi private key hằng năm
