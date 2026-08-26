FROM node:24-alpine

RUN apk add --no-cache ffmpeg tini
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY migrations ./migrations
COPY public ./public
COPY src ./src
COPY test ./test

ENV NODE_ENV=production \
    PORT=3000 \
    STATIC_ROOT=/app/public \
    MIGRATION_DIR=/app/migrations

USER node
EXPOSE 3000
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/app.js"]
