FROM node:24-alpine

WORKDIR /app

COPY package.json ./package.json
COPY src ./src

ENV HOST=0.0.0.0
ENV PORT=8789
ENV MOCK_HOSTNAME=bedjet-gateway-mock
ENV MOCK_SSID=MockWiFi

EXPOSE 8789

CMD ["node", "src/server.mjs"]
