#!/usr/bin/bash

function check_current_dir() {
  if [[ ! $(echo $PWD | grep 'argocd-working-example/helpers') ]]; then
    echo "For the correct script execution, current dir \
must be 'argocd-working-example/helpers'. Aborting." >&2; exit 1;
  fi
}

function check_components_install() {
  componentsArray=("minikube" "kubectl" "helm")
  for item in "${componentsArray[@]}"; do
    command -v "${item}" >/dev/null 2>&1 ||
      { echo "${item} is required, but it's not installed. Aborting." >&2; exit 1; }
  done
}

function check_minikube_is_running() {
  minikube profile list || minikube start
  if [[ $(minikube status --format='{{.Host}}') == "Stopped" ]]; then
    echo "Minikube is stopped. Starting minikube!";
    minikube start;
  else
    echo "Minikube is already running!"
  fi
}

function check_k8s_version() {
  currentK8sVersion=$(kubectl version --short | grep "Server Version" | awk '{gsub(/v/,$5)}1 {print $3}')
  test_version_comparator 1.23 "$currentK8sVersion" '<'
  if [[ $k8sVersion == "ok" ]]; then
    echo "current kubernetes version is ok"
  else
    minikube start --kubernetes-version=v1.23.3;
  fi
}

function add_helm_repos() {
  helm repo add argo https://argoproj.github.io/argo-helm;
  helm repo update argo;
}

function install_argocd() {
  helm upgrade -i argocd argo/argo-cd \
    --atomic \
    --create-namespace -n argocd \
    -f ../infra/values/argocd.yaml \
    --version=3.33.6 || { echo "Failure of ArgoCD installation. Aborting."; exit 1; }
}

function check_apps() {
  # Get ArgoCD admin password
  argocd_admin_pwd=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

  # Get ArgoCD server pod name
  argocd_server_pod=$(kubectl -n argocd get pod --no-headers | awk '/argocd-server/ {print $1}')

  #  Login via admin in ArgoCD
  kubectl -n argocd exec "${argocd_server_pod}" -- argocd login localhost:8080 --insecure --username=admin --password="${argocd_admin_pwd}"

  # Sync apps
  while [[ $(kubectl -n argocd exec "${argocd_server_pod}" -- \
    argocd app sync --force apps 2>/dev/null | awk '/ Error/ {print $2}' | tr -d "[:space:]") == 'Error' ]]; do
    echo "Hard refresh apps...";
    kubectl -n argocd exec "${argocd_server_pod}" -- argocd app terminate-op apps 2>/dev/null;
    kubectl -n argocd exec "${argocd_server_pod}" -- argocd app sync --force apps 2>/dev/null;
    sleep 10;
  done

  # Sync static app
  while [[ $(kubectl -n argocd exec "${argocd_server_pod}" -- \
    argocd app get static-develop | awk '/Health Status/ {print $3}') != 'Healthy' ]]; do
    echo "Satic app from develop namespace is getting up. Waiting...";
    sleep 10;
  done

  # Sync hello-kubernetes app
  while [[ $(kubectl -n argocd exec "${argocd_server_pod}" -- \
    argocd app get hello-kubernetes-test | awk '/Health Status/ {print $3}') != 'Healthy' ]]; do
    echo "hello-kubernetes app from test namespace is getting up. Waiting...";
    sleep 10;
  done

  # Sync guestbook app
  while [[ $(kubectl -n argocd exec "${argocd_server_pod}" -- \
    argocd app get guestbook-develop | awk '/Health Status/ {print $3}') != 'Healthy' ]]; do
    echo "guestbook app from develop namespace is getting up. Waiting...";
    sleep 10;
  done

  # Sync infra
  while [[ $(kubectl -n argocd exec "${argocd_server_pod}" -- \
    argocd app sync --force apps 2>/dev/null | awk '/ Error/ {print $2}' | tr -d "[:space:]") == 'Error' ]]; do
    echo "Hard refresh apps...";
    kubectl -n argocd exec "${argocd_server_pod}" -- argocd app terminate-op infra 2>/dev/null;
    kubectl -n argocd exec "${argocd_server_pod}" -- argocd app sync --force infra 2>/dev/null;
    sleep 10;
  done
}

function go_to_apps() {
  cat << EOF

Static app from develop namespace available on http://localhost:8083
Hello-kubernetes app from test namespace available on http://localhost:8082
guestbook app from develop namespace available on http://localhost:8081

ArgoCD available in  https://localhost:8443  with:
Login: admin
Password: ${argocd_admin_pwd}

EOF

  kubectl port-forward service/static -n develop 8083:80 &
  kubectl port-forward service/hello-kubernetes -n test 8082:80 &
  kubectl port-forward service/guestbook -n develop 8081:80 &
  kubectl port-forward service/argocd-server -n argocd 8443:443
}

# the comparator based on https://stackoverflow.com/a/4025065
version_comparator () {
  if [[ $1 == $2 ]]
  then
      return 0
  fi
  local IFS=.
  local i ver1=($1) ver2=($2)
  # fill empty fields in ver1 with zeros
  for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
  do
      ver1[i]=0
  done
  for ((i=0; i<${#ver1[@]}; i++))
  do
      if [[ -z ${ver2[i]} ]]
      then
          # fill empty fields in ver2 with zeros
          ver2[i]=0
      fi
      if ((10#${ver1[i]} > 10#${ver2[i]}))
      then
          return 1
      fi
      if ((10#${ver1[i]} < 10#${ver2[i]}))
      then
          return 2
      fi
  done
  return 0
}

test_version_comparator () {
  version_comparator $1 $2
  case $? in
      0) op='=';;
      1) op='>';;
      2) op='<';;
  esac
  if [[ $op != "$3" ]]
  then
      echo "Kubernetes test fail: Expected '$3', Actual '$op', Arg1 '$1', Arg2 '$2'"
      k8sVersion="not ok"
  else
      echo "Kubernetes test pass: '$1 $op $2'"
      k8sVersion="ok"
  fi
}

function main() {
  check_current_dir
  check_components_install
  check_minikube_is_running
  check_k8s_version
  add_helm_repos
  install_argocd
  check_apps
  go_to_apps
}

main
