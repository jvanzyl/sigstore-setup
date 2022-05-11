#!/usr/bin/env bash

target=$(pwd)/target
cd ${target}

function verify() {
  [ $1 -eq 0 ] && echo ">>> SUCCESS" || (echo "!!! FAILURE: $2" && exit)
}

# Modify /etc/hosts
read -r -d '' hosts <<EOF
127.0.0.1 rekor.rekor-system.svc
127.0.0.1 fulcio.fulcio-system.svc
127.0.0.1 ctlog.ctlog-system.svc
127.0.0.1 gettoken.default.svc
EOF

echo "$hosts"

# Make sure ~/.rekor/state.json is removed to avoid "root hash returned from server does not match previously persisted state"
if [ ~/.rekor/state.json ]; then
  rm -f ~/.rekor/state.json
fi

kubectl -n ctlog-system get secrets ctlog-public-key -o=jsonpath='{.data.public}' | base64 -d > ./ctlog-public.pem
export SIGSTORE_CT_LOG_PUBLIC_KEY_FILE=./ctlog-public.pem

kubectl -n fulcio-system get secrets fulcio-secret -ojsonpath='{.data.cert}' | base64 -d > ./fulcio-root.pem
export SIGSTORE_ROOT_FILE=./fulcio-root.pem

kubectl -n kourier-system port-forward service/kourier-internal 8080:80 &

echo "Testing Rekor response ..."
rekor-cli --rekor_server http://rekor.rekor-system.svc:8080 loginfo

export REKOR_URL=http://rekor.rekor-system.svc:8080
export FULCIO_URL=http://fulcio.fulcio-system.svc:8080
export ISSUER_URL=http://gettoken.default.svc:8080
# Since we run our own Rekor, when we are verifying things, we need to fetch
# the Rekor Public Key. This flag allows for that.
export SIGSTORE_TRUST_REKOR_API_PUBLIC_KEY=1
# This one is necessary to perform keyless signing with Fulcio.
export COSIGN_EXPERIMENTAL=1

echo ">>> Creating test image to sign with cosign ..."
export KO_DOCKER_REPO=registry.local:5000/knative
pushd $(mktemp -d)
go mod init sigstore.dev/testimage
cat <<EOF > main.go
package main
import "fmt"
func main() {
   fmt.Println("Hello from Sigstore World!")
}
EOF
testimage=`ko publish -B sigstore.dev/testimage`
export testimage=$testimage
echo Created image $testimage
popd

echo ">>> Signing image with cosign ..."
cosign sign --rekor-url $REKOR_URL --fulcio-url $FULCIO_URL --force --allow-insecure-registry $testimage --identity-token `curl -s $ISSUER_URL`
verify $? "Failed to sign test image with cosign."

echo ">>> Verifying image with cosign ..."
cosign verify --rekor-url $REKOR_URL --allow-insecure-registry $testimage
verify $? "Failed to verify test image with cosign."

echo ">>> Creating test attestation ..."
echo -n "sigstore test attestation" > ./predicate-file
cosign attest --predicate ./predicate-file --fulcio-url $FULCIO_URL --rekor-url $REKOR_URL --allow-insecure-registry --force $testimage --identity-token `curl -s $ISSUER_URL`
verify $? "Failed to create test attestation."

echo ">>> Verify test attestation ..."
cosign verify-attestation --rekor-url $REKOR_URL --allow-insecure-registry $testimage
verify $? "Failed to verify test attestation."
