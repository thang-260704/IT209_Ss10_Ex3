# Session 10 - Bài 3: Tối ưu hoá dung lượng Image và Layer Caching với Multi-stage Build

## 1. Mục tiêu

Refactor Dockerfile của ứng dụng Express ở bài 2 sang **multi-stage build** cho môi trường production, rồi build 2 image để so sánh:

- `hw-backend:single`: Dockerfile một stage, viết theo kiểu "chạy được là xong" (`Dockerfile.single`).
- `hw-backend:multistage`: Dockerfile hai stage đã tối ưu (`Dockerfile`).

## 2. Cấu trúc thư mục

```text
ex3/
├── .dockerignore
├── Dockerfile          # multi-stage (production)
├── Dockerfile.single   # single-stage (để so sánh)
├── package.json
├── server.js
├── README.md
└── images/
```

Mã nguồn `package.json`, `server.js` dùng lại từ bài 2.

## 3. Dockerfile.single (trước khi tối ưu)

```dockerfile
# Single-stage: dùng image Node.js đầy đủ (Debian) để vừa cài vừa chạy
FROM node:18

WORKDIR /app
ENV PORT=3000

# Copy toàn bộ mã nguồn rồi cài toàn bộ dependency (kể cả devDependencies)
COPY . .
RUN npm install

EXPOSE 3000
CMD ["node", "server.js"]
```

Các điểm chưa tối ưu:

- Base `node:18` dựa trên Debian, chứa sẵn trình biên dịch, `git`, `python3` và nhiều gói hệ thống mà ứng dụng không dùng tới khi chạy.
- `COPY . .` đứng trước `RUN npm install`: chỉ cần sửa một dòng `server.js` là cache bị phá, Docker phải cài lại toàn bộ dependency.
- Không có giai đoạn tách biệt: mọi thứ phục vụ lúc build đều nằm lại trong image chạy thật.

## 4. Dockerfile (multi-stage)

```dockerfile
# ---------- Stage 1: builder ----------
FROM node:18-alpine AS builder
WORKDIR /app

# Copy file khai báo dependency trước để tận dụng layer cache
COPY package*.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy mã nguồn sau cùng: sửa code không làm mất cache của bước npm install
COPY . .

# ---------- Stage 2: runtime ----------
FROM node:18-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=3000

# Chỉ lấy đúng sản phẩm cần để chạy từ stage builder
COPY --from=builder /app/package*.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/server.js ./

# Chạy bằng user không phải root (user "node" có sẵn trong image)
USER node

EXPOSE 3000
CMD ["node", "server.js"]
```

| Kỹ thuật | Cách làm | Tác dụng |
|---|---|---|
| Multi-stage build | `AS builder` ở stage 1, `COPY --from=builder` ở stage 2 | Image cuối chỉ chứa `node_modules`, `package*.json`, `server.js`; mọi thứ khác ở lại stage builder và bị loại bỏ |
| Base image nhẹ | `node:18-alpine` thay cho `node:18` (Debian) | Bỏ hàng trăm MB gói hệ thống không cần thiết |
| Layer caching | `COPY package*.json` → `RUN npm install` → `COPY . .` | Sửa code chỉ build lại từ bước `COPY . .`; bước `npm install` dùng cache |
| Chỉ cài dependency production | `npm install --omit=dev` + `npm cache clean --force` | Không mang devDependencies và cache npm vào image |
| Bảo mật | `USER node` | Tiến trình trong container không chạy bằng root |
| `.dockerignore` | Loại `node_modules`, `images/`, `README.md` | Build context nhỏ, không ghi đè `node_modules` đã cài |

## 5. Build và so sánh

```bash
docker build -f Dockerfile.single -t hw-backend:single .
docker build -t hw-backend:multistage .
docker images | grep hw-backend
docker image inspect -f '{{.RepoTags}} layers={{len .RootFS.Layers}}' hw-backend:single hw-backend:multistage
```

```text
hw-backend:multistage   6983d42d189e        186MB         45.6MB
hw-backend:single       42347fdd75de       1.58GB          398MB
hw-backend:v1           729cc53a9207        186MB         45.6MB   U

[hw-backend:single] layers=11
[hw-backend:multistage] layers=8
```

![Build và so sánh](images/01-build-compare.png)

### Bảng so sánh

| Tiêu chí | `hw-backend:single` | `hw-backend:multistage` | Chênh lệch |
|---|---|---|---|
| Base image | `node:18` (Debian) | `node:18-alpine` | |
| Dockerfile | 1 stage | 2 stage (`builder` → runtime) | |
| Dung lượng trên đĩa (DISK USAGE) | **1.58 GB** | **186 MB** | giảm **~88%** |
| Dung lượng nội dung (CONTENT SIZE, khi pull/push) | **398 MB** | **45.6 MB** | giảm **~88,5%** (dưới 100 MB) |
| Số layer (`RootFS.Layers`) | 11 | 8 | ít hơn 3 layer (~27%) |
| Chứa build tool, gói hệ thống thừa | Có (gcc, make, python3, git…) | Không | |
| User chạy tiến trình | `root` | `node` | |
| Build lại khi chỉ sửa `server.js` | Cài lại toàn bộ `npm install` (`COPY . .` đứng trước) | `npm install` dùng `CACHED`, build lại ~2 giây | |

Cách tính: (1.58 GB − 186 MB) / 1.58 GB ≈ 88%; (398 MB − 45.6 MB) / 398 MB ≈ 88,5%. Cả hai đều vượt yêu cầu giảm 50–70%.

Nhận xét: `hw-backend:multistage` có dung lượng bằng đúng `hw-backend:v1` của bài 2 (cũng dùng `node:18-alpine`). Với ứng dụng Node.js thuần không có bước biên dịch, phần lớn mức giảm đến từ việc đổi base image; giá trị của multi-stage nằm ở chỗ đảm bảo image runtime **chỉ** nhận `node_modules`, `package*.json`, `server.js` từ stage builder. Khi dự án có bước build thật (TypeScript, React, Spring Boot), toàn bộ compiler, devDependencies và source sẽ ở lại stage builder, mức giảm còn lớn hơn.

## 6. Kiểm tra Layer Caching

Sửa một dòng trong `server.js` rồi build lại multi-stage:

```bash
sed -i 's/Single-stage/Multi-stage/' server.js
docker build -t hw-backend:multistage .
```

```text
[+] Building 2.1s (13/13) FINISHED                                          docker:default
 => [internal] load build definition from Dockerfile                                  0.0s
 => [internal] load metadata for docker.io/library/node:18-alpine                     0.8s
 => [internal] load .dockerignore                                                     0.0s
 => [builder 1/5] FROM docker.io/library/node:18-alpine@sha256:8d6421d663b4...        0.1s
 => [internal] load build context                                                     0.0s
 => => transferring context: 349B                                                     0.0s
 => CACHED [builder 2/5] WORKDIR /app                                                 0.0s
 => CACHED [builder 3/5] COPY package*.json ./                                        0.0s
 => CACHED [builder 4/5] RUN npm install --omit=dev && npm cache clean --force        0.0s
 => [builder 5/5] COPY . .                                                            0.2s
 => CACHED [stage-1 3/5] COPY --from=builder /app/package*.json ./                    0.0s
 => CACHED [stage-1 4/5] COPY --from=builder /app/node_modules ./node_modules         0.0s
 => [stage-1 5/5] COPY --from=builder /app/server.js ./                               0.0s
 => exporting to image                                                                0.3s
 => => naming to docker.io/library/hw-backend:multistage                              0.0s
```

Các bước `COPY package*.json` và `RUN npm install` hiện chữ `CACHED`; chỉ `COPY . .` ở stage builder và `COPY --from=builder /app/server.js` ở stage runtime được chạy lại. Toàn bộ quá trình build lại chỉ mất **2.1 giây**.

![Layer cache](images/02-cache.png)

## 7. Chạy container multi-stage

```bash
docker run -d --name app-multistage -p 8083:3000 hw-backend:multistage
docker ps --filter name=app-multistage
docker logs app-multistage
curl -i http://localhost:8083/
```

```text
f4616ef4efb69595a5fa1c98fd97de6596168081e4c1d067dacdf3d72e784e45

$ docker ps --filter name=app-multistage
CONTAINER ID   IMAGE                   COMMAND                  CREATED         STATUS         PORTS                                         NAMES
f4616ef4efb6   hw-backend:multistage   "docker-entrypoint.s…"   4 seconds ago   Up 4 seconds   0.0.0.0:8083->3000/tcp, [::]:8083->3000/tcp   app-multistage

$ docker logs app-multistage
Server listening on port 3000

$ curl -i http://localhost:8083/
HTTP/1.1 200 OK
X-Powered-By: Express
Content-Type: application/json; charset=utf-8
Content-Length: 63
ETag: W/"3f-LuXTPcDONDr8CSFBxy5Lk8pJJIE"
Date: Mon, 12 Oct 2026 01:21:42 GMT
Connection: keep-alive
Keep-Alive: timeout=5

{"status":"success","message":"Hello from Docker Multi-stage!"}
```

![Chạy container multi-stage](images/03-run-curl.png)

## 8. Kết luận

- Dockerfile multi-stage tách giai đoạn `builder` (cài dependency, chuẩn bị mã nguồn) và giai đoạn runtime (chỉ `COPY --from=builder` những file cần để chạy).
- Image `hw-backend:multistage` chỉ còn **45.6 MB** nội dung (186 MB trên đĩa), giảm khoảng **88%** so với `hw-backend:single` (398 MB / 1.58 GB) và ít hơn 3 layer.
- Thứ tự `COPY package*.json` → `RUN npm install` → `COPY . .` giúp sửa code chỉ mất ~2 giây để build lại.
- Container `app-multistage` chạy ổn định bằng user `node`, `curl` trả về `HTTP/1.1 200 OK` với JSON đúng.
