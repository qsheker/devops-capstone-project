#!/usr/bin/env bash
# Run only in the disposable Accounts CI cluster.
set -euo pipefail
image=${1:?set a built image tag}
if [[ "$(kubectl config current-context)" != kind-accounts-ci ]]; then
  echo 'Expected the dedicated kind-accounts-ci context' >&2
  exit 1
fi
kubectl create namespace accounts-check
ns=(kubectl -n accounts-check)
password=$(openssl rand -hex 18)
"${ns[@]}" create secret generic postgresql --from-literal=database-name=accounts --from-literal=database-user=accounts --from-literal=database-password="$password" >/dev/null
"${ns[@]}" create deployment postgresql --image=postgres:16-alpine
"${ns[@]}" set env deployment/postgresql POSTGRES_DB=accounts POSTGRES_USER=accounts POSTGRES_PASSWORD="$password" >/dev/null
"${ns[@]}" expose deployment postgresql --port=5432
"${ns[@]}" rollout status deployment/postgresql --timeout=180s
for ((i=0; i<60; i++)); do
  if "${ns[@]}" exec deployment/postgresql -- pg_isready -q -U accounts -d accounts; then break; fi
  sleep 2
done
"${ns[@]}" exec deployment/postgresql -- pg_isready -q -U accounts -d accounts
kubectl set image --local -f deploy/deployment.yaml "accounts=$image" -o yaml | "${ns[@]}" apply -f -
"${ns[@]}" apply -f deploy/service.yaml
"${ns[@]}" rollout status deployment/accounts --timeout=180s
"${ns[@]}" get deployment,pod,service -l app=accounts -o wide
"${ns[@]}" port-forward service/accounts 18080:8080 >/tmp/accounts-ci-forward.log 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true' EXIT
curl --fail --silent --show-error --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:18080/health | jq -e '.status=="OK"'
base=http://127.0.0.1:18080/accounts
id=$(curl -fsS -H 'Content-Type: application/json' -d '{"name":"Demo","email":"demo@example.test","address":"Test Street"}' "$base" | jq -er .id)
curl -fsS "$base/$id" | jq -e --argjson id "$id" '.id==$id and .name=="Demo"'
curl -fsS -X DELETE "$base/$id"
test "$(curl -s -o /dev/null -w '%{http_code}' "$base/$id")" = 404
echo 'Verified HTTP through the Kubernetes Service: health, create, read, delete and 404.'
