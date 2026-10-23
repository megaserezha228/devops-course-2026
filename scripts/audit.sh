#!/usr/bin/env bash
# Аудит конфигурации devops-vm. Запускается на сервере:
#   ssh devops 'bash -s' < scripts/audit.sh
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no"  "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no"  "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
SSH_PORT="$(sudo sshd -T | awk '/^port /{print $2}')"
check "Порт SSH отличен от 22 (порт: ${SSH_PORT})" "не 22" \
      "$([[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]] && echo "не 22" || echo "$SSH_PORT")"
check "MaxAuthTries равно 3"               "3"   "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
check "Политика по умолчанию для входящего трафика: deny" "deny" \
      "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
SITE_DIR="/var/www/devops-site"
CERT="/etc/ssl/certs/devops.crt"
KEY="/etc/ssl/private/devops.key"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна (nginx -t)" "ok" \
      "$(sudo nginx -t >/dev/null 2>&1 && echo ok || echo error)"
check "Сертификат действует ещё не менее ${CERT_MIN_DAYS} дн." "ok" \
      "$(openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout -in "$CERT" >/dev/null 2>&1 && echo ok || echo "истекает")"
WRITABLE="$(find "$SITE_DIR" -perm -o+w 2>/dev/null | tr '\n' ' ')"
check "Нет файлов ресурса, доступных для записи всем" "" "${WRITABLE% }"
check "Права закрытого ключа TLS равны 600" "600" "$(sudo stat -c '%a' "$KEY")"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
