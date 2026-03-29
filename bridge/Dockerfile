FROM node:24-alpine

WORKDIR /app

COPY package.json ./package.json
COPY src ./src

RUN mkdir -p /app/data

ENV HOST=0.0.0.0
ENV PORT=8787
ENV DATA_PATH=/app/data/bridge.sqlite
ENV SIMULATE_FIRMWARE=true

EXPOSE 8787

CMD ["node", "src/server.mjs"]

