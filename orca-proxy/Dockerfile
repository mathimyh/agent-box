FROM node:22-slim
WORKDIR /app
RUN npm install --no-save --no-audit --no-fund ws@8 tweetnacl@1
COPY proxy.js .
# A new named volume copies this owner, so the node user can write the config.
RUN mkdir /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 6769
CMD ["node", "proxy.js", "serve"]
