# agent-box dind sidecar: a private Docker engine for one agent container.
# authz.py refuses containers that ask for host access. See docs/design.md.

FROM docker:29-dind

RUN apk add --no-cache python3

COPY authz.py /usr/local/lib/agent-box-authz.py
COPY entrypoint.sh /usr/local/bin/agent-box-dind
# The files may arrive with CRLF from a Windows checkout.
RUN sed -i 's/\r$//' /usr/local/bin/agent-box-dind /usr/local/lib/agent-box-authz.py \
 && chmod 0755 /usr/local/bin/agent-box-dind

ENV DOCKER_TLS_CERTDIR=
ENTRYPOINT ["/usr/local/bin/agent-box-dind"]
