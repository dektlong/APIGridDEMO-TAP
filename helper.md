# Helper commands for running the TAP supply chain demo (in logical order)

# showcase commands, all run as part of the demo setup
tanzu package repository add tanzu-tap-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:0.3.0 \
  --namespace tap-install

kubectl get pkgi -n tap-install

tanzu apps workload apply devx-mood \
  -f workloads//devx-mood-workload.yaml \
  --namespace dekt-apps

# run for actual deployment
tanzu apps cluster-supply-chain list

tanzu apps workload get devx-mood -n dekt-apps

# real-time debug
tanzu apps workload tail devx-mood --since 10m --timestamp  -n dekt-apps

kp images list -n dekt-apps
