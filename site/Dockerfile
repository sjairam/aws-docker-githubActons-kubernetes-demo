FROM softonic/node-prune AS prune

FROM node:20 AS build
ENV NODE_ENV production
WORKDIR /app
COPY --from=prune /go/bin/node-prune /usr/local/bin/
ADD . .
RUN npm install

FROM node:20-slim
ENV NODE_ENV production
WORKDIR /app
COPY --from=build /app .
ADD . .
EXPOSE 3000
CMD ["node", "server.js"]
