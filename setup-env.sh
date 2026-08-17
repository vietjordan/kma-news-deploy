#!/usr/bin/env bash
# Setup môi trường — sinh secret ngẫu nhiên + file .env cho deploy thật
# (docker-compose.yml). Chỉ setup env, KHÔNG pull image, KHÔNG chạy gì.
#
# Dùng:
#   ./setup-env.sh                       # sinh .env ở gốc, hỏi giá trị hạ
#                                           tầng thật (Postgres/MinIO đã
#                                           chạy sẵn ở nơi khác)
#   ./setup-env.sh --force                # sinh lại dù đã tồn tại (ghi đè)
#   ./setup-env.sh --storage=local        # dùng local-disk thay vì MinIO/S3
#
# Sau khi có .env: docker compose pull && docker compose up -d

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

FORCE=false
STORAGE="s3"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --storage=s3) STORAGE="s3" ;;
    --storage=local) STORAGE="local" ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "Không nhận diện được tham số: $arg (dùng --force, --storage=s3|local, --help)" >&2
      exit 1
      ;;
  esac
done

gen_secret() {
  openssl rand -base64 32 | tr -d '\n'
}

command -v openssl >/dev/null 2>&1 || {
  echo "Cần cài openssl để sinh secret ngẫu nhiên." >&2
  exit 1
}

ask_value() {
  local __resultvar=$1
  local prompt=$2
  local default=$3
  local hidden=$4
  local input=""

  if [ "$hidden" = "1" ]; then
    read -r -s -p "$prompt${default:+ [$default]}: " input
    echo ""
  else
    read -r -p "$prompt${default:+ [$default]}: " input
  fi

  if [ -z "$input" ]; then
    input="$default"
  fi
  printf -v "$__resultvar" '%s' "$input"
}

if [ -f "$ENV_FILE" ] && [ "$FORCE" = false ]; then
  echo "→ .env đã tồn tại, giữ nguyên (dùng --force để sinh lại)." >&2
  exit 0
fi

echo "→ Sinh .env cho production (docker-compose.yml)."
echo "  Secret Strapi/frontend sẽ tự sinh ngẫu nhiên; các giá trị hạ tầng"
echo "  (Postgres, MinIO/S3, domain frontend) cần bạn nhập vì đã chạy sẵn"
echo "  ở nơi khác, script không đoán được."
echo ""

ask_value CORS_ORIGIN_VAL "Domain frontend (CORS_ORIGIN, vd https://news.example.edu.vn)" "" 0
ask_value API_ENDPOINT_VAL "Domain backend production thật (API_ENDPOINT, frontend server-side gọi vào đây — phải khớp giá trị API_ENDPOINT đã dùng lúc kma-news-frontend CI build image, xem Infisical /kma-news-frontend)" "" 0
echo ""
echo "-- Postgres (đã chạy sẵn ở nơi khác) --"
ask_value DATABASE_HOST_VAL "DATABASE_HOST" "" 0
ask_value DATABASE_PORT_VAL "DATABASE_PORT" "5432" 0
ask_value DATABASE_NAME_VAL "DATABASE_NAME" "strapi" 0
ask_value DATABASE_USERNAME_VAL "DATABASE_USERNAME" "strapi" 0
ask_value DATABASE_PASSWORD_VAL "DATABASE_PASSWORD (ẩn khi gõ)" "" 1
echo ""

ask_value STORAGE_CHOICE "Lưu file upload ở đâu? (s3/local)" "$STORAGE" 0

AWS_BUCKET_VAL=""
AWS_ENDPOINT_VAL=""
AWS_ACCESS_KEY_ID_VAL=""
AWS_ACCESS_SECRET_VAL=""
MEDIA_ORIGIN_LINE="# storage=local: không cần MEDIA_ORIGIN."

if [ "$STORAGE_CHOICE" = "s3" ]; then
  echo ""
  echo "-- MinIO/S3 (đã chạy sẵn ở nơi khác) --"
  ask_value AWS_ENDPOINT_VAL "AWS_ENDPOINT (vd https://minio.example.edu.vn)" "" 0
  ask_value AWS_BUCKET_VAL "AWS_BUCKET" "" 0
  ask_value AWS_ACCESS_KEY_ID_VAL "AWS_ACCESS_KEY_ID" "" 0
  ask_value AWS_ACCESS_SECRET_VAL "AWS_ACCESS_SECRET (ẩn khi gõ)" "" 1
  MEDIA_ORIGIN_LINE="MEDIA_ORIGIN=${AWS_ENDPOINT_VAL%/}/${AWS_BUCKET_VAL}"
fi

echo ""
echo "-- Harbor (tag image sẽ deploy) --"
ask_value BACKEND_TAG_VAL "BACKEND_TAG" "dev" 0
ask_value FRONTEND_TAG_VAL "FRONTEND_TAG" "dev" 0

cat > "$ENV_FILE" <<EOF
# Sinh bởi setup-env.sh — dùng cho: docker compose pull && docker compose up -d
# KHÔNG commit file này vào git.

HARBOR_HOST=reg.vittapcode.id.vn
HARBOR_PROJECT=kma-news
BACKEND_TAG=$BACKEND_TAG_VAL
FRONTEND_TAG=$FRONTEND_TAG_VAL
BACKEND_PORT=1337
FRONTEND_PORT=3000

# --- Backend (Strapi) — secret tự sinh ngẫu nhiên ---
APP_KEYS="$(gen_secret),$(gen_secret)"
API_TOKEN_SALT=$(gen_secret)
ADMIN_JWT_SECRET=$(gen_secret)
TRANSFER_TOKEN_SALT=$(gen_secret)
JWT_SECRET=$(gen_secret)
ENCRYPTION_KEY=$(gen_secret)
CORS_ORIGIN=$CORS_ORIGIN_VAL

# Postgres — hạ tầng thật, đã chạy sẵn ở nơi khác
DATABASE_HOST=$DATABASE_HOST_VAL
DATABASE_PORT=$DATABASE_PORT_VAL
DATABASE_NAME=$DATABASE_NAME_VAL
DATABASE_USERNAME=$DATABASE_USERNAME_VAL
DATABASE_PASSWORD=$DATABASE_PASSWORD_VAL
DATABASE_SSL=false

# MinIO/S3 — hạ tầng thật, đã chạy sẵn ở nơi khác. Để trống AWS_BUCKET để
# dùng local-disk thay vì MinIO/S3 (backend's config/plugins.ts tự fallback).
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID_VAL
AWS_ACCESS_SECRET=$AWS_ACCESS_SECRET_VAL
AWS_REGION=us-east-1
AWS_BUCKET=$AWS_BUCKET_VAL
AWS_ENDPOINT=$AWS_ENDPOINT_VAL
AWS_FORCE_PATH_STYLE=true

# --- Frontend (Next.js) ---
# Server-only, không NEXT_PUBLIC_ — nên khớp API_ENDPOINT đã dùng lúc CI
# build image frontend, không thì ISR/dynamic render lúc chạy sẽ gọi vào
# backend khác với backend đã bake vào các trang static sẵn.
API_ENDPOINT=$API_ENDPOINT_VAL
# Runtime secret cho /api/revalidate — dùng chung cho CẢ backend (POST tới
# frontend khi content đổi, xem kma-news-backend's src/index.ts) LẪN
# frontend (kiểm tra khi nhận POST) — docker-compose.yml đọc cùng 1 biến
# này cho cả 2 service, không lệch nhau được. NEXT_PUBLIC_APP_URL mới là
# giá trị bake cứng vào image lúc CI build (ở repo kma-news-frontend),
# không sửa được qua file .env này.
REVALIDATE_SECRET=$(gen_secret)

# Server-only — origin MinIO/S3 thật, KHÔNG lộ ra client (xem
# kma-news-frontend's src/app/media/[...path]/route.ts). Phải khớp
# AWS_ENDPOINT+AWS_BUCKET ở trên.
$MEDIA_ORIGIN_LINE
EOF

chmod 600 "$ENV_FILE"

echo ""
echo "Xong. Đã sinh .env ở gốc repo (chmod 600)."
echo "Chạy: docker compose pull && docker compose up -d"
