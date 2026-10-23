# Конфигурация виртуальной машины devops-vm

Документ описывает конфигурацию учебного сервера так, чтобы её можно было
восстановить со снимка `01-clean-install`. Команды с пометкой `[VM]` выполняются
на сервере, `[Хост]` — в WSL 1 (Ubuntu) на хостовой системе Windows.

Гостевая ОС: **Ubuntu Server 26.04.1 LTS** (в методичке — 24.04). Отличия, влияющие
на настройку: вместо `sudo` установлен `sudo-rs`, OpenSSH 10.2, служба `ssh`
по умолчанию запускается через `ssh.socket`.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Имя | devops-vm |
| Тип / версия | Linux / Ubuntu (64-bit) |
| Оперативная память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ (25600 МБ), VDI, динамически расширяемый |
| Гипервизор | VirtualBox 7.1.8 на Windows |
| Имя узла / FQDN | `devops-vm` / `devops-vm.devops.local` |

## 2. Сетевые интерфейсы

| Адаптер VirtualBox | Интерфейс в ОС | Адрес | Назначение |
|---|---|---|---|
| 1 — NAT | `enp0s3` | 10.0.2.15/24 (DHCP NAT) | выход в Интернет (apt, Docker Hub), SSH через проброс порта |
| 2 — Host-only («VirtualBox Host-Only Ethernet Adapter», сеть 192.168.56.0/24) | `enp0s8` | 192.168.56.101/24 (DHCP VirtualBox, сервер 192.168.56.100) | доступ с хоста напрямую: веб-сервер, имя `devops.local` |

Адрес хостовой системы в сети Host-only — 192.168.56.1.

## 3. Правило проброса портов

Адаптер 1 (NAT), правило `ssh`: TCP, адрес хоста `127.0.0.1`, порт хоста **2222** →
порт гостя **2222** (до смены порта sshd было 22).

```bash
# [Хост] при выключенной VM — modifyvm, при запущенной — controlvm
VBoxManage.exe controlvm devops-vm natpf1 delete ssh
VBoxManage.exe controlvm devops-vm natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | UID | Группы | Аутентификация |
|---|---|---|---|
| `student` | 1000 | student, adm, cdrom, sudo, dip, plugdev, users, lxd | создан установщиком; по SSH войти не может (`AllowUsers devops`), только локальная консоль VirtualBox по паролю |
| `devops` | 1001 | devops, sudo, users (с ПР 7 также docker) | SSH только по ключу ed25519 `~/.ssh/devops_vm` (комментарий `devops-vm-key`) |

Восстановление (выполняется до усиления SSH, пока работает порт 22 и вход по паролю):

```bash
# [Хост] вход под student (порт 22 ещё проброшен на 22), сверка отпечатка ключа хоста
ssh student@127.0.0.1 -p 2222
# [VM] сверить отпечаток с показанным клиентом:
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
sudo adduser devops
sudo usermod -aG sudo devops
# sudo без пароля для devops (отступление от методички, нужно для автоматизации):
echo 'devops ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-devops
sudo chmod 440 /etc/sudoers.d/90-devops
sudo visudo -c

# [Хост] ключ уже существует в ~/.ssh/devops_vm; если нет:
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
ssh -i ~/.ssh/devops_vm -p 2222 devops@127.0.0.1 'stat -c "%a %n" ~/.ssh ~/.ssh/authorized_keys'   # 700 и 600
```

Файл `~/.ssh/config` на хосте (WSL):

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Блок `devops.local` нужен для команды `ssh devops.local`: без него клиент не знает,
какой ключ предъявлять, и сервер отвечает `Permission denied (publickey)`.

## 5. Служба SSH

- Порт: **2222** (0.0.0.0 и [::]).
- Основной файл `/etc/ssh/sshd_config` не изменяется, эталонная копия —
  `/etc/ssh/sshd_config.backup`.
- Изменения — в файле `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30

AllowUsers devops

X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

- В `/etc/ssh/sshd_config.d/50-cloud-init.conf` строка `PasswordAuthentication yes`
  закомментирована: файл читается раньше `99-hardening.conf`, а sshd применяет
  первое встреченное значение.
- Активация по сокету отключена: `ssh.socket` — disabled, `ssh.service` — enabled.

Порядок применения (действующую сессию не закрывать!):

```bash
# [VM]
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf          # содержимое выше
sudo sed -i 's/^PasswordAuthentication yes/# PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo sshd -t && sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd                                    # 0.0.0.0:2222
# [Хост] поменять проброс порта (раздел 3) и в НОВОМ терминале:
ssh devops
```

## 6. Правила межсетевого экрана

UFW 0.36.2 (backend iptables-nft). Политики: `deny (incoming)`, `allow (outgoing)`,
`disabled (routed)`. Журналирование: `medium` (`/var/log/ufw.log`).

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp | LIMIT IN | SSH rate-limited (блок при 6+ подключениях за 30 с) |
| 80/tcp | ALLOW IN | HTTP |
| 443/tcp | ALLOW IN | HTTPS |

(те же правила для IPv6)

```bash
# [VM] правило для SSH создаётся ДО включения
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp  comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
sudo ufw status verbose
```

Не использовать `ufw allow ssh`: имя `ssh` берётся из `/etc/services` и означает порт 22.

### Имена

- На хосте: `C:\Windows\System32\drivers\etc\hosts` содержит
  `192.168.56.101 devops.local` (WSL 1 копирует запись в свой `/etc/hosts`);
  после правки — `ipconfig /flushdns`.
- На сервере: `sudo hostnamectl set-hostname devops-vm`, в `/etc/hosts` строка
  `127.0.1.1 devops-vm.devops.local devops-vm`; `hostname -f` → `devops-vm.devops.local`.

## 7. Снимки состояния

| Снимок | Создан (UTC) | Состояние |
|---|---|---|
| `01-clean-install` | 2026-10-23 15:58 | чистая установка, обновления, пользователь student |
| `02-keys-configured` | 2026-10-23 16:39 | пользователь devops, ключ, `~/.ssh/config` |
| `03-ssh-hardened` | 2026-10-23 16:54 | sshd на 2222, без паролей и root, проброс 2222→2222 |
| `04-nginx-https` | 2026-10-23 17:32 | nginx, самоподписанный сертификат, HTTP → HTTPS |
| `05-docker-compose` | 2026-10-23 18:00 | Docker Engine, проект `~/app` (приложение + PostgreSQL) |

Снимки `03` и далее делаются на выключенной VM (`sudo poweroff` → снимок → запуск):
«живой» снимок `02` вызвал зависание гостевой ОС (soft lockup), потребовался сброс VM.

## 8. Веб-сервер

- Пакет: `nginx` из репозитория Ubuntu (версия 1.28.3), `sudo apt install -y nginx`.
  Правила UFW для 80/443 уже есть (раздел 6), профили `Nginx Full` не добавляются.
- Конфигурация ресурса: `/etc/nginx/sites-available/devops-site`, ссылка
  `/etc/nginx/sites-enabled/devops-site`; ссылка `sites-enabled/default` удалена
  (файл `sites-available/default` сохранён).
- Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, каталоги `755`,
  файлы `644` (права приводит `rsync --chmod=D755,F644`). Содержимое — каталог `site/`
  репозитория, доставляется `scripts/deploy.sh`.
- Сертификат: `/etc/ssl/certs/devops.crt`, `root:root`, `644`.
  Ключ: `/etc/ssl/private/devops.key`, `root:root`, `600`. Срок действия — 365 дней
  (выпущен 2026-10-23, истекает 2027-10-23). Копия сертификата на хосте: `~/devops.crt`.
- Журналы: `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log`.

Формирование сертификата:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

`/etc/nginx/sites-available/devops-site`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
```

Порядок восстановления:

```bash
# [VM]
sudo apt update && sudo apt install -y nginx rsync
sudo mkdir -p /var/www/devops-site && sudo chown -R devops:devops /var/www/devops-site
# сертификат (команда выше), конфигурация (файл выше)
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
# [Хост]
scp devops:/etc/ssl/certs/devops.crt ~/devops.crt
scripts/deploy.sh
```

## 9. Контейнеризация

- Docker Engine 29.9.2 (containerd 2.4.2, плагин Compose v5.6.1) из официального
  репозитория `https://download.docker.com/linux/ubuntu`, ветка `resolute`; пакет
  `docker.io` не используется. Межсетевой backend Docker — iptables.
- Группа `docker`: `devops` (у него есть sudo; членство в группе равносильно root).
- Проект: `/home/devops/app` (копия каталога `app/` репозитория, доставляется rsync),
  имя проекта Compose — `app`, контейнеры `app-app-1` и `app-db-1`, сеть `app_backend`.
- Секреты: `/home/devops/app/.env`, владелец `devops`, права `600`, создаётся только
  на сервере из `.env.example` со случайным паролем; в репозитории — только `.env.example`,
  `.env` в `.gitignore`.
- Порты: приложение — `127.0.0.1:5000` (только для Nginx); PostgreSQL 5432 не публикуется,
  доступен приложению по имени `db` в сети `backend`.
- Том: `app_db_data` → `/var/lib/postgresql/data` (образ `postgres:16-alpine`).
- Обратный прокси: в HTTPS-блок `/etc/nginx/sites-available/devops-site` добавлено
  расположение `/app/` (статический ресурс `/` сохранён):

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

Порядок восстановления:

```bash
# [VM] Docker Engine
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" | sudo tee /etc/apt/sources.list.d/docker.sources
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops          # затем новая SSH-сессия

# [Хост] доставка проекта
rsync -avz --delete --exclude=.env app/ devops:app/

# [VM] секреты и запуск
cd ~/app && cp .env.example .env && chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
# Nginx: добавить location /app/ (фрагмент выше), затем
sudo nginx -t && sudo systemctl reload nginx
```

## Проверка

```bash
ssh devops 'bash -s' < scripts/audit.sh; echo $?      # ожидается 0
```
