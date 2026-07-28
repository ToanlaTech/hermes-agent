# Runbook — Thêm 1 bot Telegram mới (Hermes profile) "1 phát ăn ngay"

Tạo thêm một bot Telegram độc lập trên pod `hermes-0` bằng **Hermes profile riêng**, mỗi bot có SOUL/memory/session/identity riêng, chạy như **per-profile s6 gateway** (KHÔNG dùng multiplex), và **tự phục hồi sau khi pod restart**.

> Đúc kết từ thực chiến trên **Hermes v0.19.0 (2026.7.20)**, Docker s6-overlay, `HERMES_HOME=/opt/data` trên PVC.
> ⚠️ **KHÔNG bật `gateway.multiplex_profiles`** — bản này dính bug #66887 (session/memory của profile phụ bị route về store default → bot trả lời sai danh tính). Cách bền vững & sạch là mỗi profile 1 gateway process riêng.

---

## 0. Vì sao KHÔNG multiplex — và 4 "cửa tử" phải né

| # | Vấn đề | Hệ quả nếu bỏ qua | Cách né (đã nằm trong recipe) |
|---|--------|-------------------|-------------------------------|
| 1 | `gateway.multiplex_profiles` bug #66887 / #64934 | Bot phụ resume session/memory của default → trả lời sai danh tính | Multiplex OFF; chạy per-profile s6 gateway riêng |
| 2 | `--clone` copy `platforms.webhook` (bug port-bind) | Dưới multiplex bị skip cả profile; per-profile thì đụng port | `platforms.webhook.enabled: false` |
| 3 | Per-profile gateway auto-bật `api_server` từ `API_SERVER_KEY` ambient | Đụng port 8642 với default → gateway crash-loop | `platforms.api_server.enabled: false` |
| 4 | **`--clone` copy luôn `memories/MEMORY.md` + `USER.md`** (bug #10376) | Bot mới "nhiễm" persona/kiến thức của default (ví dụ xưng "Hinata") | Xoá rỗng 2 file memory ngay sau khi clone |

Phụ: `TELEGRAM_ALLOWED_USERS` (env) đọc bằng `os.getenv` → **không** dùng được per-profile. Allowlist per-profile phải đặt trong `config.yaml` → `gateway.platforms.telegram.allow_from`.

> ⚠️ **Cửa tử #5 — RAM/OOM khi thêm gateway.** Mỗi per-profile gateway là 1 process Python ~150–250Mi. Container `hermes` (StatefulSet) mặc định `resources.limits.memory: 1536Mi`. Thêm gateway thứ 5 làm container **OOMKilled** (exit 137, `lastState.reason=OOMKilled`) — 5 gateway cần ~1.27Gi steady-state, spike lúc start vượt 1536Mi. **Trước khi thêm bot làm tràn limit, nâng memory limit:**
> ```bash
> kubectl -n hermes patch statefulset hermes --type='json' -p='[
>   {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"3Gi"},
>   {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"512Mi"}]'
> ```
> Pod roll 1 lần; 4 profile đang `running` tự phục hồi qua reconcile, rồi mới `gateway start` bot mới. Quy tắc: limit ≥ (số_gateway × 0.3Gi) + 0.5Gi.

---

## 1. Chuẩn bị (đặt biến 1 lần)

Chạy trên máy local (đã có kubeconfig). Sửa 4 biến rồi copy nguyên block về sau.

```bash
export KUBECONFIG='/Users/mdm/WorkSpace/Certs/f5s-k8s-cluster-kubeconfig.yaml'
export NS=hermes
export POD=hermes-0

# 👇 SỬA 4 dòng này cho bot mới
PROFILE="english"                                   # tên profile: chữ thường, [a-z0-9_-]
BOT_TOKEN="123456:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # token @BotFather
OWNER_ID="5281416406"                               # Telegram user id được phép chat (+ admin)
DESC="English conversation tutor. Practice speaking/writing English."  # mô tả (kanban routing)
```

**Lấy Telegram user id của bạn:** nhắn `/start` cho `@userinfobot`, hoặc xem log `inbound message ... chat=<id>`.

---

## 2. Verify token hợp lệ (trước khi làm gì)

```bash
curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe" \
 | python3 -c 'import json,sys;d=json.load(sys.stdin);r=d.get("result",{});print("ok:",d.get("ok"),"| @"+str(r.get("username")),"| id:",r.get("id"))'
```
Kỳ vọng `ok: True`. Nếu `False` → token sai, dừng lại.

---

## 3. Tạo + cấu hình profile (chạy 1 phát)

Tạo profile (clone config/.env/SOUL/skills từ profile active = default):

```bash
kubectl -n $NS exec $POD -c hermes -- sh -c "
  hermes profile create '$PROFILE' --clone --description '$DESC'
"
```

Cấu hình toàn bộ trong 1 block (né cả 4 gotcha). ⚠️ **`kubectl exec` KHÔNG có flag `--env`** (đó là của `kubectl run`) → truyền 3 biến bằng cách nối chuỗi: prefix nháy-kép cho shell local expand `$PROFILE/$BOT_TOKEN/$OWNER_ID`, phần thân nháy-đơn giữ nguyên `$PH/$ENV`/python heredoc.

```bash
kubectl -n $NS exec $POD -c hermes -- sh -c "PROFILE='$PROFILE'; BOT_TOKEN='$BOT_TOKEN'; OWNER_ID='$OWNER_ID'; "'
set -e
PH="/opt/data/profiles/$PROFILE"

# (Gotcha #4) Xoá rỗng memory clone — nếu không bot sẽ nhiễm persona của default
mkdir -p "$PH/memories/.bak-clone"
cp "$PH/memories/MEMORY.md" "$PH/memories/USER.md" "$PH/memories/.bak-clone/" 2>/dev/null || true
: > "$PH/memories/MEMORY.md"; : > "$PH/memories/USER.md"

# .env: đặt token mới, bỏ home-channel clone của default
ENV="$PH/.env"
grep -v -E "^TELEGRAM_HOME_CHANNEL(_THREAD_ID)?=|^TELEGRAM_BOT_TOKEN=" "$ENV" > "$ENV.tmp" && mv "$ENV.tmp" "$ENV"
printf "TELEGRAM_BOT_TOKEN=%s\n" "$BOT_TOKEN" >> "$ENV"
chmod 600 "$ENV"

# config.yaml: (Gotcha #2,#3) tắt webhook + api_server; multiplex off; allowlist per-profile
python3 - "$PH/config.yaml" "$OWNER_ID" <<PY
import sys, yaml
p, uid = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(p)) or {}
d.setdefault("platforms", {})
d["platforms"]["api_server"] = {"enabled": False}
d["platforms"]["webhook"]    = {"enabled": False}
gw = d.setdefault("gateway", {}); gw.pop("multiplex_profiles", None)
tg = gw.setdefault("platforms", {}).setdefault("telegram", {})
tg["allow_from"]       = [uid]   # ai được chat DM
tg["allow_admin_from"] = [uid]   # + full slash-command
yaml.safe_dump(d, open(p, "w"), sort_keys=False, allow_unicode=True)
print("platforms:", d["platforms"]); print("telegram:", tg)
PY

# Session store sạch
rm -f "$PH/sessions/sessions.json" "$PH/state.db" "$PH/state.db-shm" "$PH/state.db-wal" 2>/dev/null || true

# Quyền
chown -R 10000:10000 "$PH"
echo "OK: profile $PROFILE configured"
'
```

### Đặt persona (SOUL.md)

SOUL.md là danh tính (slot #1 của system prompt). Soạn local rồi copy vào:

```bash
# ví dụ soạn nhanh; thực tế viết file rồi cp
cat > /tmp/${PROFILE}_SOUL.md <<'EOF'
# SOUL — <Tên bot>

You are **<Tên>**, <mô tả vai trò>.
<hành vi, giọng điệu, ranh giới...>
EOF

kubectl -n $NS cp /tmp/${PROFILE}_SOUL.md $NS/$POD:/opt/data/profiles/$PROFILE/SOUL.md -c hermes
kubectl -n $NS exec $POD -c hermes -- chown 10000:10000 /opt/data/profiles/$PROFILE/SOUL.md
```

---

## 4. Khởi động gateway (supervised s6) + verify

```bash
# Đăng ký + start service s6 cho profile (KHÔNG dùng 'gateway run' thủ công)
kubectl -n $NS exec $POD -c hermes -- sh -c "hermes -p '$PROFILE' gateway start"

# Verify: telegram connected + home đúng + không conflict
kubectl -n $NS exec $POD -c hermes -- sh -c "PROFILE='$PROFILE'; "'
for i in $(seq 1 12); do
  python3 -c "import json;d=json.load(open(\"/opt/data/profiles/$PROFILE/gateway_state.json\"));exit(0 if d[\"platforms\"][\"telegram\"][\"state\"]==\"connected\" else 1)" 2>/dev/null && break
  sleep 4
done
python3 -c "import json;d=json.load(open(\"/opt/data/profiles/$PROFILE/gateway_state.json\"));print(\"state:\",d[\"gateway_state\"],\"| telegram:\",d[\"platforms\"][\"telegram\"][\"state\"])"
grep -iE "Address already|Another gateway|ERROR" /opt/data/profiles/$PROFILE/logs/*.log 2>/dev/null | tail -3 || echo "(no conflicts)"
'

# Xem toàn cảnh
kubectl -n $NS exec $POD -c hermes -- sh -c "hermes profile list; echo; ls /run/service | grep gateway"
```

Kỳ vọng: `state: running | telegram: connected`, profile mới hiện `running`, có slot `gateway-<profile>`.
> Dòng log `another gateway already holds the dispatcher lock (.../kanban/...)` là **bình thường** — profile phụ nhường kanban dispatch cho default, KHÔNG phải lỗi port.

**Test:** nhắn bot mới trên Telegram → phải trả lời đúng persona trong SOUL.md, memory trống, không nhiễm profile khác.

---

## 5. Độ bền qua pod restart (tự động, không cần làm gì)

Image có sẵn `docker/cont-init.d/02-reconcile-profiles` → `hermes_cli.container_boot`: mỗi lần container boot, nó duyệt `profiles/` và **tự start lại** profile nào có `gateway_state = running`. Slot s6 nằm trên tmpfs (`/run/service`, mất khi restart) nhưng được dựng lại tự động từ state trên PVC. **Không cần sửa Dockerfile/manifest.**

Mọi thứ (profile dir, `.env`, `config.yaml`, memory) nằm trên PVC `/opt/data` → bền vững. `config-seed` idempotent (chỉ seed `config.yaml` khi chưa có) nên không đè.

---

## 6. Vận hành

```bash
P=english   # tên profile

# Sửa persona rồi áp dụng
kubectl -n $NS cp SOUL.md $NS/$POD:/opt/data/profiles/$P/SOUL.md -c hermes
kubectl -n $NS exec $POD -c hermes -- sh -c "hermes -p $P gateway restart"

# Đổi allowlist / thêm người dùng: sửa gateway.platforms.telegram.allow_from trong config rồi restart

# Reset hội thoại (nếu bot "dính" context cũ): wipe session store rồi restart
kubectl -n $NS exec $POD -c hermes -- sh -c "
  hermes -p $P gateway stop; sleep 2
  rm -f /opt/data/profiles/$P/sessions/sessions.json /opt/data/profiles/$P/state.db*
  hermes -p $P gateway start"

# Xem log
kubectl -n $NS exec $POD -c hermes -- sh -c "tail -40 /opt/data/profiles/$P/logs/gateway.log"

# Dừng hẳn (không auto-restart nữa)
kubectl -n $NS exec $POD -c hermes -- sh -c "hermes -p $P gateway stop"

# Xoá profile
kubectl -n $NS exec $POD -c hermes -- sh -c "hermes -p $P gateway stop; hermes profile delete $P"
```

---

## 7. Checklist "ăn ngay" (dán vào PR/ticket)

- [ ] `getMe` trả `ok: True`, token **khác** mọi bot đang chạy (1 token = 1 poller, trùng sẽ 409/refuse)
- [ ] `hermes profile create <p> --clone`
- [ ] **Xoá rỗng** `memories/MEMORY.md` + `USER.md`  ← quan trọng nhất, tránh nhiễm persona
- [ ] `.env`: set `TELEGRAM_BOT_TOKEN` mới, bỏ `TELEGRAM_HOME_CHANNEL*`
- [ ] `config.yaml`: `platforms.api_server.enabled=false`, `platforms.webhook.enabled=false`
- [ ] `config.yaml`: `gateway.platforms.telegram.allow_from`/`allow_admin_from = [<owner_id>]`
- [ ] Không có `gateway.multiplex_profiles`
- [ ] `SOUL.md` = persona mong muốn
- [ ] `hermes -p <p> gateway start` → `gateway_state = running / telegram connected`, không conflict port
- [ ] Test Telegram: đúng persona, memory trống

---

### Tham khảo
- Bug multiplex session-store: NousResearch/hermes-agent **#66887**, **#64934**
- Clone copy memory: **#10376**  ·  Secret scope per-profile: **#52446 / #49415**  ·  SOUL cache: **#28078**
- Docs: <https://hermes-agent.nousresearch.com/docs/user-guide/profiles> · <.../multi-profile-gateways>
