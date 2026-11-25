# openvpn-compose

[English](README.md)

一個用一組指令就能部署的 OpenVPN 伺服器：clone、填好 `.env`、執行 `docker compose up -d`。

它會自己產生憑證，並為每個用戶端各產生一份可直接匯入的 `.ovpn` 設定檔。所有跟環境有關的設定（位址、埠、網段、DNS、用戶端名稱）都放在 `.env`，所以搬伺服器、換 IP、加裝置、換路由器，都只要改一個設定再執行一次 `up`。

這個 repo 只負責執行 OpenVPN。DNS 記錄與雲端防火牆規則由你自己設定，請見[本專案不處理的事](#本專案不處理的事)。

## 需求

- 一台 Linux 主機，具備 Docker Engine 與 Compose v2、`/dev/net/tun`，以及核心的 iptables 支援。
- 主機上有一個可從外部連入的 UDP 埠（預設 1194）。

除非你的使用者已加入 `docker` 群組，否則以下指令請加上 `sudo`。

## 快速開始

```sh
git clone <此 repository> openvpn-compose && cd openvpn-compose
cp .env.example .env
$EDITOR .env                  # 至少要設定 VPN_HOST
docker compose up -d
```

第一次執行會建置映像，建立 CA、伺服器憑證，以及 `VPN_CLIENTS` 中每個名稱的憑證與設定檔，然後啟動伺服器。設定檔會寫到 `data/clients/<名稱>.ovpn`。

把設定檔複製到要連線的裝置並匯入。這些檔案的擁有者是 root、權限為 600（設定檔內含該用戶端的私鑰），所以要用 `sudo` 讀取：

```sh
# 在你自己的電腦上執行
ssh user@server 'sudo cat openvpn-compose/data/clients/vpn-client.ovpn' > vpn-client.ovpn
```

## 設定

在 `.env` 中設定（參考 `.env.example`）。值為純文字，不需要加引號。

| 變數 | 預設值 | 說明 |
|---|---|---|
| `VPN_HOST` | 無，必填 | 用戶端連線用的位址：網域名稱或 IP。會寫進每份設定檔的 `remote` 那一行。 |
| `VPN_PORT` | `1194` | 在主機上發布的 UDP 埠。伺服器本身在容器內一律監聽 1194。 |
| `VPN_SUBNET` | `172.16.88.0/24` | 分配給已連線用戶端的私有網段（前綴長度 8 到 29）。不可與隧道兩端的任何網路重疊：伺服器本身的網路、Docker 的網路、用戶端所在的區域網路。 |
| `VPN_DNS` | `1.1.1.1,1.0.0.1` | 推送給用戶端的 DNS 伺服器，以逗號分隔。留空表示不推送。 |
| `VPN_REDIRECT_GATEWAY` | `true` | `true`：用戶端所有流量都走 VPN，伺服器成為它們的出口。`false`：只有送往 VPN 網段的流量走隧道，用戶端原本的上網方式不變。 |
| `VPN_CLIENTS` | `vpn-client` | 每個名稱產生一組憑證與設定檔，以逗號分隔。只能使用英文字母、數字、`-` 和 `_`。請一個裝置用一個名稱：兩台裝置不能同時用同一張憑證連線，而且伺服器日誌顯示的就是這個名稱。 |
| `VPN_CERT_DAYS` | `3650` | 新簽發憑證的有效天數。到期日晚於 2037 年的設定會被拒絕，因為較舊的 32 位元用戶端（許多路由器）可能無法正確處理更晚的日期。 |

## 日常操作

**套用修改過的設定。** 編輯 `.env`，然後執行 `docker compose up -d`。
- `VPN_SUBNET`、`VPN_DNS`、`VPN_REDIRECT_GATEWAY`：伺服器會以新的值重新啟動，設定檔不受影響。
- `VPN_HOST`、`VPN_PORT`：設定檔會被改寫，需要在裝置上重新匯入（如果 `VPN_HOST` 是網域名稱，而你只是把它指向新的位址，用戶端就完全不用變）。

**新增裝置。** 在 `VPN_CLIENTS` 加一個名稱，執行 `docker compose up -d`，然後取得 `data/clients/<名稱>.ovpn`。既有的用戶端不受影響。

**更換裝置。** 如上，替新裝置取一個新名稱。舊裝置的憑證在撤銷之前仍然有效（見下一項）。

**撤銷存取權。** 這裡沒有憑證撤銷清單。要讓所有已簽發的憑證失效：停止伺服器、刪除 `data/`、執行 `docker compose up -d`，再把新的設定檔重新匯入每一台裝置。把名稱從 `VPN_CLIENTS` 拿掉只是不再產生，它的憑證仍然有效。

**更新。** `git pull && docker compose up -d --build`。

**日誌。** `docker compose logs -f openvpn`。啟動後要看到 `Initialization Sequence Completed`，裝置連線時會看到它的名稱。

**伺服器憑證更新。** 伺服器憑證無效或在 30 天內到期時，`init` 會重新簽發，但執行中的伺服器只在啟動時讀取它，所以如果 `docker compose logs init` 顯示已重新簽發，請執行 `docker compose restart openvpn`。使用預設的有效期，這大約是十年才會發生一次的事。

## 檔案放在哪裡

```
data/                  第一次執行時建立，不會被提交
  ca/                  ca.crt、ca.key          CA；只有簽發憑證時才需要 ca.key
  server/              ca.crt、server.crt、     伺服器容器唯一看得到的目錄（唯讀）
                       server.key、tls-crypt.key
  clients/             <名稱>.crt、<名稱>.key、<名稱>.ovpn
```

`data/` 內有私鑰，已被 git 忽略，也不會被放進映像的建置內容。請備份它：遺失 CA 就表示每台裝置都需要新的設定檔。`git clean -fdx` 會把它刪掉。

因為執行伺服器並不需要 CA 私鑰，設定檔都產生好之後，你可以把 `data/ca/ca.key` 移到安全的地方。伺服器照常運作，只有要簽發新憑證時才需要把它放回來，缺少時 `init` 會告訴你。

### 沿用既有的 PKI

為了讓裝置在重建或搬移之後仍能繼續使用，請在第一次 `up` 之前，把舊的檔案依相同結構放好：

```
data/ca/ca.crt  data/ca/ca.key
data/clients/<名稱>.crt  data/clients/<名稱>.key      # <名稱> 必須列在 VPN_CLIENTS 中
data/server/tls-crypt.key
```

`init` 會沿用已存在的檔案，只補簽缺少的，通常只有伺服器憑證。裝置能繼續運作，是因為它們的憑證沒有變。設定檔會被重新產生；如果原本的設定檔就是由這個 repo 產生的，且 `VPN_HOST` 與 `VPN_PORT` 沒有改變，新檔案會與原本的逐位元組相同，所以不需要重新匯入。

## 本專案不處理的事

- **DNS。** 如果 `VPN_HOST` 是網域名稱，建立它的記錄由你負責。直接使用 IP 位址也可以。
- **防火牆。** 請在雲端的安全群組或主機防火牆放行 `VPN_PORT` 的入站 UDP，如果你知道用戶端從哪裡連入，也請在那裡限制來源位址。不要依賴 `ufw` 之類的主機防火牆：Docker 用它自己的 iptables 規則發布埠，會繞過 `ufw`。
- **IPv6、TCP、多台伺服器、個別撤銷憑證。** 這個伺服器是 IPv4 加 UDP。

## 運作方式

`compose.yaml` 用同一個映像執行兩個服務。`init`（`init-pki.sh`）每次 `up` 執行一次，把 `data/` 底下缺少的東西補上後結束。`openvpn`（`entrypoint.sh`）依環境變數產生 `server.conf`，在自己的網路命名空間內設定轉發與 NAT，並以非特權使用者身分執行 OpenVPN。它只需要 `NET_ADMIN` 和 `/dev/net/tun`，不需要 `--privileged`，也不使用主機網路。

## 疑難排解

- **用戶端一直連不上。** 確認 UDP `VPN_PORT` 對該用戶端是開放的、`VPN_HOST` 解析到這台伺服器，以及設定檔是最新的那一份。
- **連得上，但沒有網路。** 確認 `VPN_REDIRECT_GATEWAY` 是 `true`、伺服器本身可以連上網際網路，而且 `VPN_SUBNET` 沒有和用戶端已使用的網路重疊。
- **`init` 因錯誤而停止。** 錯誤訊息會指出是哪個設定或檔案。常見原因是 `.env` 的值有誤，或 `data/` 內有建立到一半的檔案。
- **`net.ipv4.ip_forward is off`。** 你的 Docker 設定拒絕了 `compose.yaml` 中的 `sysctls`，請在主機上啟用轉發。
