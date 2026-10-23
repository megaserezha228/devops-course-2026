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

Снимки `03` и далее делаются на выключенной VM (`sudo poweroff` → снимок → запуск):
«живой» снимок `02` вызвал зависание гостевой ОС (soft lockup), потребовался сброс VM.

## Проверка

```bash
ssh devops 'bash -s' < scripts/audit.sh; echo $?      # ожидается 0
```
