#!/usr/bin/env bash

# - unique cluster name instead of kind
# - use helm charts? seems not
# - check for docker registry and re-use?
# - kind for m1 macs? works in emulation mode as rosetta is installed by default now
# - connect to kind network?

version="0.2.9"
arch="$(uname -m)"
os="$(uname)"

target="$(pwd)/target"
rm -rf ${target} 2> /dev/null
mkdir -p ${target} 2> /dev/null
cd ${target}

echo ">>> Retrieving version ${version} of setup-kind.sh ..."
curl -Lo setup-kind.sh https://github.com/sigstore/scaffolding/releases/download/v${version}/setup-kind.sh
chmod u+x setup-kind.sh
./setup-kind.sh

docker rm -f `docker ps -a | grep 'registry:2' | awk -F " " '{print $1}'`
echo ">>> Installing Sigstore scaffolding ..."
curl -Lo release.yaml https://github.com/sigstore/scaffolding/releases/download/v${version}/release.yaml
kubectl apply -f release.yaml
echo "Waiting for all the knative services to be up and running ..."
kubectl wait --timeout 10m -A --for=condition=Ready ksvc --all
echo ">>> Waiting for all scaffolding jobs to complete ..."
kubectl wait --timeout=15m -A --for=condition=Complete jobs --all
[ $? -eq 0 ] && echo "SUCCESS" || (echo "FAILURE: scaffolding jobs didn't complete." && exit)

echo ">>> Get ctlog-public-key and add to default namespace ..."
kubectl -n ctlog-system get secrets ctlog-public-key -oyaml | sed 's/namespace: .*/namespace: default/' > ctlog-public-key.yaml
kubectl apply -f ctlog-public-key.yaml
echo ">>> Get fulcio-secret and add to default namespace ..."
kubectl -n fulcio-system get secrets fulcio-secret -oyaml | sed 's/namespace: .*/namespace: default/' > fulcio-secret.yaml
kubectl apply -f fulcio-secret.yaml
echo ">>> Create test jobs (checktree, sign-job, and verify-job) ..."
curl -Lo testrelease.yaml https://github.com/sigstore/scaffolding/releases/download/v${version}/testrelease.yaml
kubectl apply -f testrelease.yaml
echo ">>> Waiting for jobs to complete ..."
kubectl wait --timeout=5m --for=condition=Complete jobs checktree sign-job verify-job
[ $? -eq 0 ] && echo "SUCCESS" || (echo "FAILURE: test jobs didn't complete." && exit)
