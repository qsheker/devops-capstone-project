#!/usr/bin/env bash
# Integration run on an isolated GitHub-hosted runner. No public registry or cluster credentials.
set -euo pipefail
: "${REPO_URL:?}" "${REVISION:?}"
if [[ "$(kubectl config current-context)" != kind-accounts-tekton ]]; then
  echo 'Expected the disposable kind-accounts-tekton context' >&2
  exit 1
fi
mkdir -p run-evidence
catalog=https://raw.githubusercontent.com/tektoncd/catalog/112374ce1262b133a77300bd8133445722605e04/task
kubectl apply -f https://github.com/tektoncd/pipeline/releases/download/v0.59.4/release.yaml >/dev/null
kubectl -n tekton-pipelines wait --for=condition=Available deployment --all --timeout=240s
kubectl create namespace accounts-check
ns=(kubectl -n accounts-check)
"${ns[@]}" create serviceaccount pipeline
# Grant only the app deployment permissions inside the throwaway namespace.
"${ns[@]}" create role accounts-delivery --verb=get,list,watch,create,patch,update --resource=deployments.apps,services
"${ns[@]}" create role accounts-observe --verb=get,list,watch --resource=pods,replicasets.apps
for role in accounts-delivery accounts-observe; do
  "${ns[@]}" create rolebinding "$role" --role="$role" --serviceaccount=accounts-check:pipeline
done
curl -fsSL --retry 3 "$catalog/buildah/0.8/buildah.yaml" | sed -e 's|^apiVersion: tekton.dev/v1$|apiVersion: tekton.dev/v1beta1|' -e 's/^kind: Task$/kind: ClusterTask/' | kubectl apply -f -
"${ns[@]}" apply -f "$catalog/git-clone/0.9/git-clone.yaml" -f "$catalog/flake8/0.1/flake8.yaml"
"${ns[@]}" apply -f tekton/tasks.yaml -f tekton/pipeline.yaml
password=$(openssl rand -hex 18)
"${ns[@]}" create secret generic postgresql --from-literal=database-name=accounts --from-literal=database-user=accounts --from-literal=database-password="$password" >/dev/null
"${ns[@]}" create deployment postgresql --image=postgres:16-alpine
"${ns[@]}" set env deployment/postgresql POSTGRES_DB=accounts POSTGRES_USER=accounts POSTGRES_PASSWORD="$password" >/dev/null
"${ns[@]}" expose deployment postgresql --port=5432
"${ns[@]}" rollout status deployment/postgresql --timeout=180s
# The registry is private to the ephemeral Docker network. It has no host port and no credentials.
docker run -d --name accounts-registry --network kind registry:2 >/dev/null
registry_host=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' accounts-registry)
registry="$registry_host:5000"
node=accounts-tekton-control-plane
docker exec "$node" mkdir -p "/etc/containerd/certs.d/$registry"
printf 'server = "http://%s"\n[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n' "$registry" "$registry" |
  docker exec -i "$node" tee "/etc/containerd/certs.d/$registry/hosts.toml" >/dev/null
# Tag the image with the source revision.
image="$registry/accounts:${REVISION:0:12}"
cat <<YAML | "${ns[@]}" apply -f -
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata: {name: accounts-check}
spec:
  pipelineRef: {name: cd-pipeline}
  serviceAccountName: pipeline
  podTemplate:
    securityContext: {fsGroup: 65532}
  params:
    - {name: repo-url, value: "$REPO_URL"}
    - {name: branch, value: "$REVISION"}
    - {name: build-image, value: "$image"}
    - {name: registry-tls-verify, value: "false"}
  workspaces:
    - name: pipeline-workspace
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources: {requests: {storage: 2Gi}}
YAML
collect() {
  "${ns[@]}" get pipelinerun accounts-check > run-evidence/pipelinerun-status.txt
  "${ns[@]}" get taskruns -l tekton.dev/pipelineRun=accounts-check -o wide >> run-evidence/pipelinerun-status.txt
  : > run-evidence/pipelinerun.txt
  for task in clone lint tests build deploy; do
    pod=$("${ns[@]}" get pod -l "tekton.dev/pipelineRun=accounts-check,tekton.dev/pipelineTask=$task" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || continue
    for container in $("${ns[@]}" get pod "$pod" -o jsonpath='{.spec.containers[*].name}'); do
      printf '\n[%s : %s]\n' "$task" "$container" >> run-evidence/pipelinerun.txt
      "${ns[@]}" logs "$pod" -c "$container" >> run-evidence/pipelinerun.txt 2>&1 || true
    done
  done
  cat run-evidence/pipelinerun-status.txt
}
trap collect EXIT
for ((attempt=1; attempt<=120; attempt++)); do
  status=$("${ns[@]}" get pipelinerun accounts-check -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
  case "$status" in
    True) break;;
    False) "${ns[@]}" describe pipelinerun accounts-check; exit 1;;
  esac
  if ((attempt % 6 == 0)); then "${ns[@]}" get pods -o wide; fi
  sleep 7
done
test "$status" = True
test "$("${ns[@]}" get deploy accounts -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$image"
"${ns[@]}" rollout status deployment/accounts --timeout=60s
"${ns[@]}" port-forward service/accounts 18080:8080 >/tmp/tekton-http.log 2>&1 &
pid=$!
curl -fsS --retry 15 --retry-connrefused --retry-delay 1 http://127.0.0.1:18080/health | jq -e '.status=="OK"'
kill "$pid"
