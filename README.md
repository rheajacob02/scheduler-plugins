# Scheduler Plugin Setup on CloudLab

This guide walks through setting up the **network-aware scheduler plugin** on CloudLab Kubernetes cluster.

---

## Prerequisites

- CloudLab cluster already set up and running.
- **node0** (control plane) has:
  - Docker for building images.
  - Go (see version in scheduler-plugins `go.mod`; the repo may use a recent Go version).
- `kubectl` configured from node0 against the cluster.

---

## Part 1: Build the Scheduler-Plugins Images (on node0)

All build steps are on **node0** (or any machine with Docker and Go). The Makefile uses `hack/build-images.sh`, which builds both the kube-scheduler and controller images.

### Step 1.1: Install Go (if not already installed)

Use the **same Go version as in `scheduler-plugins/go.mod`** (e.g. the first line `go 1.24.0`). Example for 1.24:

```bash
cd ~
# Check go.mod: grep "^go " go.mod  → use that version
curl -LO https://go.dev/dl/go1.24.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.24.0.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
export PATH=$PATH:/usr/local/go/bin
go version
```

If `go.mod` says a different version (e.g. `go 1.21`), install that instead.

### Step 1.2: Clone scheduler-plugins and build images

Clone the repo. Building from the repo root produces both images.

**Build with Make using the built-in local target**:

```bash
cd ~/scheduler-plugins
make local-image
```

Then retag so you can save/load without a registry:

```bash
docker tag localhost:5000/scheduler-plugins/kube-scheduler:v0.0.0 scheduler-plugins/kube-scheduler:latest
docker tag localhost:5000/scheduler-plugins/controller:v0.0.0 scheduler-plugins/controller:latest
```

### Step 1.3: Save images and load into cluster nodes

So the cluster can use the images without a registry, save them to tarballs and load them into containerd on each node (as you did for OVN-Kubernetes).

**On node0:**

```bash
# Save both images to tarballs
docker save scheduler-plugins/kube-scheduler:latest -o ~/scheduler-plugins-kube-scheduler.tar
docker save scheduler-plugins/controller:latest -o ~/scheduler-plugins-controller.tar

# Load into node0's containerd (kubelet uses k8s.io namespace)
sudo ctr -n k8s.io image import ~/scheduler-plugins-kube-scheduler.tar
sudo ctr -n k8s.io image import ~/scheduler-plugins-controller.tar

# Verify
sudo ctr -n k8s.io image ls | grep scheduler-plugins
```

**Copy tarballs to workers and load (from your laptop or from node0):**

```bash
# From laptop (or from node0 with ssh to workers)
scp node0:~/scheduler-plugins-kube-scheduler.tar .
scp node0:~/scheduler-plugins-controller.tar .

scp scheduler-plugins-kube-scheduler.tar node1:~/
scp scheduler-plugins-controller.tar node1:~/
# Repeat for node2, node3, ...
```

**On each worker node (node1, node2, ...):**

```bash
sudo ctr -n k8s.io image import ~/scheduler-plugins-kube-scheduler.tar
sudo ctr -n k8s.io image import ~/scheduler-plugins-controller.tar
sudo ctr -n k8s.io image ls | grep scheduler-plugins
```

---

## Part 2: Build AppGroup and NetworkTopology Controllers (for network-aware)

The network-aware plugins (**TopologicalSort**, **NetworkOverhead**) depend on:

- **AppGroup** CRD and **appgroup-controller** (manages app groups and topology order).
- **NetworkTopology** CRD and **networktopology-controller** (manages network cost data).

The manifests under `manifests/appgroup` and `manifests/networktopology` reference images like `localhost:5000/appgroup-controller/controller:latest`. To avoid using a registry, build these controllers from source and tag them so your manifests can use them.

### Step 2.1: Build AppGroup controller

```bash
# Clone and build on node0
git clone https://github.com/diktyo-io/appgroup-controller.git
cd appgroup-controller
# Follow that repo’s README to build the controller image, e.g.:
# docker build -t appgroup-controller/controller:latest .
# Then save and load as above, and use image: appgroup-controller/controller:latest in deploy-appgroup-controller.yaml
```

### Step 2.2: Build NetworkTopology controller

```bash
git clone https://github.com/diktyo-io/networktopology-controller.git
cd networktopology-controller
# Build image, e.g.: docker build -t networktopology-controller/controller:latest .
# Save, copy to nodes, load into containerd; then use that image in deploy-networktopology-controller.yaml
```

After building, **save**, **copy**, and **load** these images on all nodes (same as in Part 1.3), and update the deployment YAMLs to use the tags you built (e.g. `appgroup-controller/controller:latest`, `networktopology-controller/controller:latest`).

---

## Part 3: Install CRDs and RBAC (node0)

### Step 3.1: Install CRDs

```bash
cd ~/scheduler-plugins

# run these first to copy kubeconfig to your profile and create env variable pointing to it 
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=~/.kube/config

# AppGroup CRD (required for network-aware)
kubectl apply -f manifests/crds/appgroup.diktyo.x-k8s.io_appgroups.yaml

# NetworkTopology CRD (required for NetworkOverhead)
kubectl apply -f manifests/crds/networktopology.diktyo.x-k8s.io_networktopologies.yaml

# run these instead if the crds in crd folder just has path to the actual yaml files
kubectl apply -f manifests/appgroup/crd.yaml
kubectl apply -f manifests/networktopology/crd.yaml
```

### Step 3.2: Apply RBAC for network-aware scheduler

```bash
kubectl apply -f manifests/networktopology/cluster-role.yaml
```

This creates the `network-aware-scheduler` ServiceAccount and ClusterRole/ClusterRoleBindings for AppGroup and NetworkTopology.

---

## Part 4: Deploy Network-Aware Controllers (node0)

If you built the AppGroup and NetworkTopology controllers, deploy them and point to your built images.

### Step 4.1: Fix controller image references

Edit the controller manifests to use your local image tags (no registry):

- **manifests/appgroup/deploy-appgroup-controller.yaml**  
  Set `image` to the image you built and loaded (e.g. `appgroup-controller/controller:latest`) and `imagePullPolicy: IfNotPresent` (or `Never`).

- **manifests/networktopology/deploy-networktopology-controller.yaml**  
  Set `image` to your networktopology-controller image and `imagePullPolicy: IfNotPresent` (or `Never`).

### Step 4.2: Deploy controllers

```bash
# Create namespace (if not created by the manifests)
kubectl create namespace network-aware-controllers --dry-run=client -o yaml | kubectl apply -f -

# Deploy AppGroup controller first
kubectl apply -f manifests/appgroup/deploy-appgroup-controller.yaml

# Then NetworkTopology controller
kubectl apply -f manifests/networktopology/deploy-networktopology-controller.yaml

kubectl get pods -n network-aware-controllers
```

---

## Part 5: Deploy the Network-Aware Scheduler (second scheduler)

Run the scheduler-plugins kube-scheduler as a **second scheduler** with the name `network-aware-scheduler`, using a ConfigMap for the scheduler config.

### Step 5.1: Create the scheduler ConfigMap

Use the network-aware config from the repo. The config API version must match what your kube-scheduler supports (v1 or v1beta3).

```bash
kubectl apply -f manifests/networktopology/scheduler-configmap-v1beta3.yaml
```

That creates a ConfigMap named **`network-aware-scheduler-config`**.

### Step 5.2: Create the scheduler Deployment

Create a Deployment that runs your **built** scheduler image and mounts the ConfigMap above.

```yaml
# Save as manifests/networktopology/deploy-network-aware-scheduler.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: network-aware-scheduler
  namespace: kube-system
  labels:
    component: network-aware-scheduler
spec:
  replicas: 1
  selector:
    matchLabels:
      component: network-aware-scheduler
  template:
    metadata:
      labels:
        component: network-aware-scheduler
    spec:
      serviceAccountName: network-aware-scheduler
      containers:
        - name: scheduler
          image: scheduler-plugins/kube-scheduler:latest
          imagePullPolicy: IfNotPresent
          args:
            - --config=/etc/kubernetes/scheduler-config.yaml
          volumeMounts:
            - name: config
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: network-aware-scheduler-config
```

Apply it (from scheduler-plugins repo root):

```bash
kubectl apply -f manifests/networktopology/deploy-network-aware-scheduler.yaml
kubectl get pods -n kube-system -l component=network-aware-scheduler
```

Ensure the Pod runs and the config format (v1 vs v1beta3) matches your kube-scheduler binary.

---

## Part 6: Create NetworkTopology and AppGroup for Online Boutique

The NetworkOverhead plugin uses a **NetworkTopology** CR; TopologicalSort uses an **AppGroup** CR. Define them and label your nodes so that region/zone topology exists (e.g. `topology.kubernetes.io/region`, `topology.kubernetes.io/zone`).

### Step 6.1: Label nodes (region/zone)

If your CloudLab nodes don’t have region/zone labels, add them so the example NetworkTopology can be used:

```bash
# Example: node0 in region us-west-1, zone z1; node1 in us-west-1, zone z2; node2 in us-east-1, z3
kubectl label nodes node0 topology.kubernetes.io/region=us-west-1 topology.kubernetes.io/zone=z1
kubectl label nodes node1 topology.kubernetes.io/region=us-west-1 topology.kubernetes.io/zone=z2
kubectl label nodes node2 topology.kubernetes.io/region=us-east-1 topology.kubernetes.io/zone=z3
```

Adjust region/zone names to match the `networkTopology-example.yaml` you use (see Step 6.2).

### Step 6.2: Create NetworkTopology CR

The manifest is already in the repo. From the scheduler-plugins repo root:

```bash
kubectl apply -f manifests/networktopology/networkTopology-example.yaml
```

The example uses `weightsName: "UserDefined"` and `networkTopologyName: "net-topology-test"`. The scheduler config’s `networkTopologyName` should match the NetworkTopology `metadata.name` (e.g. `net-topology-test` in the example).

### Step 6.3: Create AppGroup for Online Boutique

Create an AppGroup that defines the Online Boutique app and optional topology order. Save it e.g. as **`manifests/networktopology/appgroup-online-boutique.yaml`** (or `manifests/appgroup/appgroup-online-boutique.yaml`). Example:

```yaml
# manifests/networktopology/appgroup-online-boutique.yaml
apiVersion: appgroup.diktyo.x-k8s.io/v1alpha1
kind: AppGroup
metadata:
  name: online-boutique
  namespace: default
spec:
  numMembers: 11   # number of workloads (services) in Online Boutique
  topologySortingAlgorithm: Kahn
  workload:
    - workload: frontend
      priority: 1
      dependencies:
        - productcatalogservice
        - recommendationservice
        - cartservice
        - currencyservice
        - shippingservice
        - checkoutservice
    - workload: checkoutservice
      priority: 2
      dependencies:
        - cartservice
        - currencyservice
        - shippingservice
        - productcatalogservice
    # Add other workloads and dependencies as needed; see manifests/appgroup or KEP 260 for full examples.
```

Apply from the scheduler-plugins repo root (use the path where you saved the file):

```bash
kubectl apply -f manifests/networktopology/appgroup-online-boutique.yaml
```

You can start with a minimal AppGroup and expand; the exact workload list should match the labels you use on deployments (`appgroup.diktyo.x-k8s.io.workload`).

---

## Part 7: Deploy Online Boutique with the network-aware scheduler

Use the provided manifest that sets `schedulerName: network-aware-scheduler` and the correct AppGroup labels.

```bash
kubectl apply -f manifests/networktopology/deploy-onlineBoutique-with-networkAware-scheduler.yaml
# OR
kubectl apply -f manifests/appgroup/deploy-onlineBoutique-with-networkAware-scheduler.yaml
```

These manifests already set:

- `schedulerName: network-aware-scheduler`
- Labels like `appgroup.diktyo.x-k8s.io: online-boutique` and `appgroup.diktyo.x-k8s.io.workload: <service>`

### Verify

```bash
kubectl get pods -o wide
kubectl get appgroups
kubectl get networktopologies
```

Pods should transition to Running and be placed according to NetworkOverhead/TopologicalSort once the controllers and CRs are healthy.

---

## Summary: Order of operations

| Step | Action |
|------|--------|
| 1   | Build scheduler-plugins kube-scheduler and controller images (Make or docker build). |
| 2   | Save images, load into containerd on all nodes (node0 + workers). |
| 3   | (Optional) Build AppGroup and NetworkTopology controllers; save and load on all nodes. |
| 4   | Install CRDs: AppGroup, NetworkTopology. |
| 5   | Apply network-aware RBAC (cluster-role.yaml). |
| 6   | Deploy AppGroup and NetworkTopology controllers (with your built images). |
| 7   | Create scheduler ConfigMap and Deployment for `network-aware-scheduler`. |
| 8   | Label nodes (region/zone); create NetworkTopology CR and AppGroup CR. |
| 9   | Deploy Online Boutique with `schedulerName: network-aware-scheduler` and AppGroup labels. |

---

## Troubleshooting

- **`/usr/bin/env: 'bash\r': No such file or directory` when running make:** The script has Windows line endings (CRLF). On the machine where you run `make` (e.g. CloudLab node), run: `sed -i 's/\r$//' hack/build-images.sh` (and any other `.sh` files you run). Or install `dos2unix` and run `dos2unix hack/build-images.sh`. A `.gitattributes` with `*.sh text eol=lf` helps keep scripts as LF after clone/pull.
- **`make build-images` fails with "unknown flag: --use" or buildx errors:** The script uses `docker buildx create --use` for local builds; some Docker installs (e.g. on CloudLab) don’t have the buildx plugin or use an older version. The repo’s `hack/build-images.sh` is patched to ignore that failure and continue (so the default builder is used). If you still get errors on the `buildx build` step, skip the Makefile and build with plain **docker build** (see **Option B** in Step 1.2): run the two `docker build` commands there—no buildx required.
- **Scheduler pod not starting:** Check `kubectl logs -n kube-system deployment/network-aware-scheduler`. Ensure the config API version (v1 vs v1beta3) matches the binary and the ConfigMap key is `scheduler-config.yaml` and mounted at `/etc/kubernetes/scheduler-config.yaml`.
- **Pods stuck Pending:** Confirm the scheduler is running and that the pod’s `schedulerName` is `network-aware-scheduler`. Check scheduler logs for filter/score errors.
- **ImagePullBackOff:** Use `imagePullPolicy: IfNotPresent` or `Never` and ensure images were loaded with `ctr -n k8s.io image import`.
- **AppGroup/NetworkTopology not found:** Ensure CRDs are installed and the appgroup-controller and networktopology-controller pods are running and that the AppGroup and NetworkTopology CRs exist and match the names in the scheduler config and workload labels.

For more on the network-aware plugins and config, see:

- `scheduler-plugins/pkg/networkaware/README.md`
- `scheduler-plugins/kep/260-network-aware-scheduling/README.md`
