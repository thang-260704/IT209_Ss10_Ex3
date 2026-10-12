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
