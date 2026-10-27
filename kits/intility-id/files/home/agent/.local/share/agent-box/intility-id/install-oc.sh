#!/bin/sh
# kits/intility-id install step. Runs once as root when the sandbox is
# created. Every step is safe to run again.
set -eu

# OpenShift client, pinned. Two sandboxes created on different days get the
# same version. Change the pin on purpose. The checksum comes from the same
# mirror directory. The install stops when the archive does not match it.
OC_VERSION=4.15.59

if [ ! -x /usr/local/bin/oc ]; then
  oc_base="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$OC_VERSION"
  curl -fsSL "$oc_base/openshift-client-linux.tar.gz" -o /tmp/openshift-client-linux.tar.gz
  curl -fsSL "$oc_base/sha256sum.txt" -o /tmp/ocp-sha256sum.txt
  grep ' openshift-client-linux.tar.gz$' /tmp/ocp-sha256sum.txt > /tmp/oc-check.txt
  (cd /tmp && sha256sum -c ocp-check.txt)
  tar -xzf /tmp/openshift-client-linux.tar.gz -C /usr/local/bin oc kubectl
  rm -f /tmp/openshift-client-linux.tar.gz /tmp/ocp-sha256sum.txt /tmp/oc-check.txt
fi
