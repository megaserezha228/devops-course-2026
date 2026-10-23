#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

# Требование 2: работаем из корня репозитория независимо от текущего каталога
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

REMOTE="devops"                     # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
LOCAL_DIR="${REPO_ROOT}/site/"

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         echo "Использование: $0 [--dry-run]" >&2; exit 2 ;;
esac

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "Ошибка: не найден ${LOCAL_DIR}index.html, доставка отменена" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Ошибка: в репозитории есть незафиксированные изменения, доставка отменена:" >&2
    git status --short >&2
    exit 1
fi

COMMIT="$(git rev-parse --short HEAD)"

# 3. Синхронизация: одно SSH-соединение, без интерактивного запроса пароля
rsync -az --delete --chmod=D755,F644 --itemize-changes ${DRY_RUN} \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
    echo "Пробный запуск: показан план для коммита ${COMMIT}, сервер не изменён"
    exit 0
fi

# 5. Проверка доступности с проверкой сертификата (без -k)
if ! curl -fsS -o /dev/null --max-time 10 --cacert "$CA_CERT" "$SITE_URL/"; then
    echo "Ошибка: ${SITE_URL} недоступен после доставки" >&2
    exit 1
fi

echo "Доставлен коммит ${COMMIT}: ${SITE_URL} отвечает"
