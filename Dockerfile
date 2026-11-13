FROM node:18-alpine

WORKDIR /app

ENV PORT=10004 HOST=0.0.0.0

# 复制 package.json 和 package-lock.json
COPY package*.json ./

# 安装依赖
RUN npm ci --only=production

# 复制源代码
COPY . .

# 复制 .env.example 为默认 .env
RUN cp .env.example .env

# 创建数据和图片目录
RUN mkdir -p data public/images

# 暴露端口
EXPOSE 10004

# 启动应用
CMD ["sh", "-c", "node scripts/init-docker-env.js && node src/config/init-env.js && npm start"]
