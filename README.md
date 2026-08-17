# kma-news-deploy

Ops repo cho KMA News. Không chứa code ứng dụng — chỉ có `docker-compose.yml`,
script sinh `.env`, và hướng dẫn deploy thủ công trên host production.

Code và CI nằm ở 2 repo riêng:
- **kma-news-backend** — Strapi 5 CMS, build & publish image `reg.vittapcode.id.vn/kma-news/backend`.
- **kma-news-frontend** — Next.js 15 site, build & publish image `reg.vittapcode.id.vn/kma-news/frontend`.

Cả 2 repo đó đều **không có CD** — mỗi lần push lên `main` (hoặc chạy tay
`workflow_dispatch`), CI chỉ build & đẩy image mới lên Harbor. Việc deploy
image đó lên server là thao tác thủ công, làm từ repo này.

## Vì sao tách 3 repo

Trước đây backend + frontend + deploy config nằm chung 1 monorepo. Tách ra vì:
- Backend và frontend deploy độc lập, không cần đồng bộ commit.
- Frontend CI build gọi thẳng vào backend production thật lúc
  `generateStaticParams`/SSG (dùng `API_ENDPOINT`, server-only — xem
  kma-news-frontend's CLAUDE.md, mục "Environment"/"Deployment"). Gộp chung
  1 repo dễ khiến người ta tưởng push 1 commit là cả 2 CI "cùng lúc" ra bản
  mới nhất — thực ra frontend CI vẫn gọi vào backend **đang chạy trên
  server**, không phải backend vừa build. Tách repo buộc phải nghĩ rõ thứ tự
  deploy (xem mục dưới) thay vì ngộ nhận nhờ chung 1 lần push.

## Deploy lần đầu

1. Đảm bảo Postgres và MinIO/S3 (nếu dùng) đã chạy sẵn ở nơi khác — file này
   không khởi động chúng.
2. `./setup-env.sh` — hỏi các giá trị hạ tầng thật (Postgres, MinIO/S3, domain
   frontend cho CORS, tag image), tự sinh các secret Strapi/Next.js còn lại.
   Xem `--help` để biết thêm tuỳ chọn (`--storage=local` nếu không dùng MinIO/S3).
3. `docker compose pull && docker compose up -d`
4. Cấu hình reverse proxy + domain trỏ vào cổng `FRONTEND_PORT`/`BACKEND_PORT`
   (mặc định 3000/1337) — **không nằm trong phạm vi repo này**, tự làm riêng.

## Deploy các lần sau / thứ tự khi đổi cả backend lẫn frontend

Vì không có CD, image mới trên Harbor **không tự động chạy** — server vẫn
chạy image cũ cho tới khi bạn `pull && up -d`. Điều này quan trọng khi một
thay đổi động tới cả backend lẫn frontend (vd thêm field mới ở Strapi mà
frontend code đã sửa theo):

1. Push/merge thay đổi **backend** trước → đợi `kma-news-backend` CI build
   xong image mới trên Harbor.
2. Cập nhật `BACKEND_TAG` trong `.env` (nếu dùng tag cố định thay vì `dev`),
   rồi `docker compose pull backend && docker compose up -d backend`. Xác
   nhận backend mới đã sống (gọi thử API, kiểm tra field/schema mới).
3. **Sau đó** mới push thay đổi frontend (hoặc chạy `workflow_dispatch` cho
   `kma-news-frontend` nếu code đã push từ trước) — lúc này CI build frontend
   sẽ gọi đúng backend mới, không phải backend cũ.
4. `docker compose pull frontend && docker compose up -d frontend`.

Nếu deploy sai thứ tự, hậu quả nhẹ là frontend build với dữ liệu cũ (ISR sẽ
tự cập nhật sau qua webhook revalidate), nặng là build lỗi nếu code frontend
mới trông đợi field/response shape mà backend cũ chưa có.

Không có staging — test trực tiếp trên production, cẩn thận: backup Postgres
trước khi đổi schema, deploy vào giờ ít traffic, mỗi lần deploy chỉ 1 thay đổi
rủi ro.

## Rollback

Đổi `BACKEND_TAG`/`FRONTEND_TAG` trong `.env` về tag cũ hơn (xem tag có sẵn
trên Harbor), rồi `docker compose pull && docker compose up -d` lại.

## Revalidation (ISR) tự động khi sửa content

`docker-compose.yml` đã nối sẵn: backend POST vào
`http://frontend:3000/api/revalidate` (địa chỉ nội bộ Docker network, không
phải domain public) mỗi khi tạo/sửa/xoá/publish/unpublish content — xem
`kma-news-backend`'s `src/index.ts`. Không cần cấu hình gì thêm ở đây,
`setup-env.sh` tự sinh `REVALIDATE_SECRET` dùng chung cho cả 2 service.
Cố tình **không** dùng tính năng Webhooks trong Strapi admin UI vì nó chặn
mọi URL không public-reachable (xem `kma-news-backend`'s `CLAUDE.md`).

## Thêm secrets trên GitHub

Cả `kma-news-backend` và `kma-news-frontend` cần cùng bộ **repo secrets** +
**repo variables** dưới đây để job "Fetch ... from Infisical" chạy được
(Settings → Secrets and variables → Actions, trên **từng repo** — không share
được giữa 2 repo, phải add ở cả 2):

| Loại | Tên | Giá trị |
|---|---|---|
| Secret | `INFISICAL_CLIENT_ID` | Client ID của Infisical Machine Identity (xem mục dưới) |
| Secret | `INFISICAL_CLIENT_SECRET` | Client Secret tương ứng |
| Variable | `INFISICAL_DOMAIN` | URL instance Infisical (vd `https://app.infisical.com` hoặc self-host) |
| Variable | `INFISICAL_PROJECT_SLUG` | Slug của project Infisical chứa secrets `kma-news` |

Dùng `gh` CLI cho nhanh (chạy trong từng repo sau khi đã `gh repo clone`/`cd`
vào đó):

```bash
gh secret set INFISICAL_CLIENT_ID
gh secret set INFISICAL_CLIENT_SECRET
gh variable set INFISICAL_DOMAIN --body "https://app.infisical.com"
gh variable set INFISICAL_PROJECT_SLUG --body "<slug-project>"
```

**Runner**: cả 2 workflow đều chạy trên `runs-on: ci` (self-hosted runner có
label `ci`). Nếu runner đó trước đây được đăng ký cho repo monorepo cũ, kiểm
tra lại nó được đăng ký ở mức **organization** (dùng chung được cho repo mới)
hay ở mức **repository** (phải đăng ký lại/đăng ký thêm cho từng repo mới) —
Settings → Actions → Runners.

## Thêm secrets trên Infisical

CI đọc 2 secret-path khác nhau, cả 2 đều nằm dưới environment `dev`
(`INFISICAL_ENVIRONMENT: dev` trong mỗi workflow):

### `/harbor` — dùng bởi cả backend và frontend CI (đẩy image lên Harbor)

| Key | Giá trị |
|---|---|
| `HARBOR_USERNAME` | Username tài khoản robot/user có quyền push lên `reg.vittapcode.id.vn/kma-news` |
| `HARBOR_PASSWORD` | Password/token tương ứng |

### `/kma-news-frontend` — chỉ dùng bởi frontend CI (build-time)

| Key | Giá trị |
|---|---|
| `API_ENDPOINT` | Domain backend production thật đang chạy (vd `https://api.news.example.edu.vn`) — **phải** là backend đã deploy xong, không phải backend sắp deploy (xem "Deploy order" ở trên). Server-only, không baked vào client bundle — nhưng vẫn cần lúc build vì `generateStaticParams` gọi backend trực tiếp. Giá trị này cũng phải khớp với `API_ENDPOINT` trong `.env` ở repo này (`docker-compose.yml`'s frontend service đọc lại lúc runtime), không thì ISR/dynamic render sẽ gọi vào backend khác với backend đã bake vào các trang static sẵn. |
| `NEXT_PUBLIC_APP_URL` | Domain frontend production thật (dùng cho canonical/hreflang tags) — baked vào client bundle, không đổi được qua `.env` ở repo này. |

Setup Machine Identity cho `INFISICAL_CLIENT_ID`/`INFISICAL_CLIENT_SECRET`:
Infisical dashboard → Organization Settings → Machine Identities → tạo mới
identity → gán quyền đọc (`read`) trên project + 2 path trên → gán
Universal Auth → copy Client ID/Secret vào GitHub secrets ở trên. Identity
này dùng chung được cho cả 2 repo CI.

## File trong repo này

- `docker-compose.yml` — chạy 2 container `backend`/`frontend`, kéo image từ
  Harbor. Không chạy Postgres/MinIO (đã có sẵn ở nơi khác).
- `.env.example` — mẫu, copy thành `.env` (hoặc dùng `setup-env.sh`) rồi điền
  giá trị thật. Không commit `.env` thật.
- `setup-env.sh` — sinh `.env` với secret ngẫu nhiên + hỏi giá trị hạ tầng thật.
