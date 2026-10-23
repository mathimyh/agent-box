# 007: Agents need the `oc` CLI

Priority: medium. Status: open.

## Problem

Agents in containers cannot use the OpenShift CLI (`oc`). The image does not have it, and the container has no cluster login.

## Proposed fix

1. Install `oc` in the image. Pin the version that matches the clusters.
2. Decide how the agent gets a login. Do not mount the host `~/.kube/config`, because it holds tokens for every cluster and context that the user has.

## Decisions needed

- Which clusters and namespaces must agents reach, and must they write or only read?
- Login method:
  - A service account per cluster with a namespace-scoped role. The launcher passes a kubeconfig with only that context. This is the smallest access, and the token does not expire with the user session.
  - A user login per container (`oc login --web` or `indev`), kept in the home volume. This is simple, but every container then has the full access of the user.
- Do workers need `oc` (for example to read logs or check a deployment), or only the coordinator on the host?

## Verify

1. `oc whoami` and `oc get pods -n <namespace>` work in a container.
2. Access to a namespace outside the scope fails.
3. No kubeconfig with other contexts is in the container.
