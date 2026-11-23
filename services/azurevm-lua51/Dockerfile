FROM node:20-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends lua5.1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY lib/lua-sources/azurevm ./lib/lua-sources/azurevm
COPY services/azurevm-lua51 ./services/azurevm-lua51

ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

CMD ["node", "services/azurevm-lua51/server.mjs"]
