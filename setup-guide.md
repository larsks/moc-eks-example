# EKS Private Cluster Setup Guide

Step-by-step CLI commands for creating a private EKS cluster in us-east-1
with SSM-based access (no public API endpoint).

## Architecture overview

```
┌──────────────────────────────── VPC 10.0.0.0/16 ─────────────────────────────────┐
│                                                                                  │
│  ┌───── Public 10.0.1.0/24 (1a) ──────┐  ┌───── Public 10.0.2.0/24 (1b) ──────┐  │
│  │  Internet Gateway ↔ NAT Gateway    │  │  (ALB nodes, redundancy)           │  │
│  │  Public ALBs (Keycloak, etc.)      │  │                                    │  │
│  └────────────────────────────────────┘  └────────────────────────────────────┘  │
│                                                                                  │
│  ┌──── Private 10.0.10.0/24 (1a) ─────┐  ┌──── Private 10.0.20.0/24 (1b) ─────┐  │
│  │  EKS Nodes (managed node group)    │  │  EKS Nodes                         │  │
│  │  SSM Bastion (t3.micro)            │  │  Internal NLBs (LDAP, etc.)        │  │
│  │  Internal NLBs (LDAP, etc.)        │  │                                    │  │
│  └────────────────────────────────────┘  └────────────────────────────────────┘  │
│                                                                                  │
│  EKS Control Plane (AWS-managed, private endpoint)                               │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

```bash
# Verify tools
aws --version        # AWS CLI v2
eksctl version       # 0.230.0+
kubectl version --client
session-manager-plugin  # needed for SSM tunnel in step 9

# Verify identity
aws sts get-caller-identity
```

The SSM Session Manager plugin is not bundled with the AWS CLI. Install it
separately (Fedora/RHEL):

```bash
curl -o /tmp/session-manager-plugin.rpm \
  https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm
sudo dnf install -y /tmp/session-manager-plugin.rpm
```

## Step 0: Set variables

All subsequent commands reference these. Run this block first. As resources
are created, later steps append their IDs to `session.sh` so you can
`source session.sh` in another terminal to pick up all variables.

```bash
CLUSTER_NAME="moc-eks"
REGION="us-east-1"
AZ1="${REGION}a"
AZ2="${REGION}b"
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_1_CIDR="10.0.1.0/24"
PUBLIC_SUBNET_2_CIDR="10.0.2.0/24"
PRIVATE_SUBNET_1_CIDR="10.0.10.0/24"
PRIVATE_SUBNET_2_CIDR="10.0.20.0/24"

# Write initial variables to session.sh for use in other terminals
cat > session.sh <<VARS
CLUSTER_NAME="$CLUSTER_NAME"
REGION="$REGION"
AZ1="$AZ1"
AZ2="$AZ2"
VPC_CIDR="$VPC_CIDR"
PUBLIC_SUBNET_1_CIDR="$PUBLIC_SUBNET_1_CIDR"
PUBLIC_SUBNET_2_CIDR="$PUBLIC_SUBNET_2_CIDR"
PRIVATE_SUBNET_1_CIDR="$PRIVATE_SUBNET_1_CIDR"
PRIVATE_SUBNET_2_CIDR="$PRIVATE_SUBNET_2_CIDR"
VARS
```

## Step 1: Create VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${CLUSTER_NAME}-vpc}]" \
  --query 'Vpc.VpcId' --output text)

echo "VPC_ID=$VPC_ID" | tee -a session.sh

# Enable DNS hostnames (required for EKS private endpoint DNS resolution)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
```

## Step 2: Create subnets

```bash
# --- Public subnets ---
PUBLIC_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_1_CIDR" \
  --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-${AZ1}}]" \
  --query 'Subnet.SubnetId' --output text)

PUBLIC_SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_2_CIDR" \
  --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-${AZ2}}]" \
  --query 'Subnet.SubnetId' --output text)

# Not needed: NAT Gateways use an explicit Elastic IP (not the subnet's
# auto-assign pool), and ALBs get public IPs from AWS regardless of this
# setting. No EC2 instances are launched in the public subnets.
# aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_1" --map-public-ip-on-launch
# aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_2" --map-public-ip-on-launch

# --- Private subnets ---
PRIVATE_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_1_CIDR" \
  --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-${AZ1}}]" \
  --query 'Subnet.SubnetId' --output text)

PRIVATE_SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_2_CIDR" \
  --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-${AZ2}}]" \
  --query 'Subnet.SubnetId' --output text)

echo "PUBLIC_SUBNET_1=$PUBLIC_SUBNET_1" | tee -a session.sh
echo "PUBLIC_SUBNET_2=$PUBLIC_SUBNET_2" | tee -a session.sh
echo "PRIVATE_SUBNET_1=$PRIVATE_SUBNET_1" | tee -a session.sh
echo "PRIVATE_SUBNET_2=$PRIVATE_SUBNET_2" | tee -a session.sh
```

## Step 3: Create Internet Gateway

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

echo "IGW_ID=$IGW_ID" | tee -a session.sh
```

## Step 4: Create NAT Gateway

A single NAT Gateway keeps costs down for dev. For production, create one
per AZ for high availability.

```bash
# Allocate an Elastic IP for the NAT Gateway
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${CLUSTER_NAME}-nat-eip}]" \
  --query 'AllocationId' --output text)

NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_1" \
  --allocation-id "$EIP_ALLOC" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-nat}]" \
  --query 'NatGateway.NatGatewayId' --output text)

echo "NAT_GW_ID=$NAT_GW_ID" | tee -a session.sh

# Wait for NAT Gateway to become available (takes 1-2 minutes)
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
echo "NAT Gateway is available"
```

## Step 5: Create route tables

```bash
# --- Public route table ---
PUBLIC_RT=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-rt}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id "$PUBLIC_RT" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"

aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_1"
aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_2"

# --- Private route table ---
PRIVATE_RT=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-rt}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id "$PRIVATE_RT" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID"

aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_1"
aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_2"

echo "PUBLIC_RT=$PUBLIC_RT" | tee -a session.sh
echo "PRIVATE_RT=$PRIVATE_RT" | tee -a session.sh
```

## Step 6: Tag subnets for EKS load balancer discovery

The AWS Load Balancer Controller uses these tags to know which subnets to
place ALBs (public) and NLBs (internal) into. These could have been
included in `--tag-specifications` when creating the subnets in step 2;
they're broken out here to make their purpose visible.

```bash
# Public subnets: internet-facing load balancers (Keycloak, etc.)
for SUBNET in $PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2; do
  aws ec2 create-tags --resources "$SUBNET" --tags \
    Key=kubernetes.io/role/elb,Value=1 \
    Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared
done

# Private subnets: internal load balancers (LDAP, etc.)
for SUBNET in $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2; do
  aws ec2 create-tags --resources "$SUBNET" --tags \
    Key=kubernetes.io/role/internal-elb,Value=1 \
    Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared
done
```

## Step 7: Create SSM bastion

The bastion lives in a private subnet — SSM doesn't need inbound ports. The
SSM agent reaches AWS endpoints through the NAT Gateway.

```bash
# --- Create IAM role for the bastion ---
aws iam create-role --role-name "${CLUSTER_NAME}-bastion-role" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

aws iam attach-role-policy --role-name "${CLUSTER_NAME}-bastion-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name "${CLUSTER_NAME}-bastion-profile"
aws iam add-role-to-instance-profile \
  --instance-profile-name "${CLUSTER_NAME}-bastion-profile" \
  --role-name "${CLUSTER_NAME}-bastion-role"

# IAM propagation takes a few seconds
sleep 10

# --- Find latest Amazon Linux 2023 AMI ---
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-2023*-x86_64" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

echo "AMI_ID=$AMI_ID" | tee -a session.sh

# --- Create a security group for the bastion (outbound only) ---
BASTION_SG=$(aws ec2 create-security-group \
  --group-name "${CLUSTER_NAME}-bastion-sg" \
  --description "SSM bastion - outbound only" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

# Default SG allows all outbound and no inbound, which is what we want.
aws ec2 create-tags --resources "$BASTION_SG" \
  --tags Key=Name,Value="${CLUSTER_NAME}-bastion-sg"

echo "BASTION_SG=$BASTION_SG" | tee -a session.sh

# --- Launch the bastion ---
BASTION_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$PRIVATE_SUBNET_1" \
  --security-group-ids "$BASTION_SG" \
  --iam-instance-profile Name="${CLUSTER_NAME}-bastion-profile" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-bastion}]" \
  --metadata-options "HttpTokens=required" \
  --query 'Instances[0].InstanceId' --output text)

echo "BASTION_ID=$BASTION_ID" | tee -a session.sh

# Wait for the instance to be running
aws ec2 wait instance-running --instance-ids "$BASTION_ID"

# Wait for SSM agent to register (usually 30-60 seconds after boot)
echo "Waiting for SSM agent to register..."
for i in $(seq 1 30); do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${BASTION_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
  if [ "$STATUS" = "Online" ]; then
    echo "Bastion is SSM-ready"
    break
  fi
  sleep 5
done
```

## Step 8: Create EKS cluster

This uses eksctl with a config file pointing to the VPC and subnets we
created. The cluster starts with both public and private API endpoints
enabled — we'll disable the public endpoint after verifying SSM tunnel
access (step 10).

Before running eksctl, generate the config file with the subnet IDs filled in:

```bash
cat > /tmp/eksctl-config.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "1.36"

vpc:
  id: ${VPC_ID}
  subnets:
    public:
      ${AZ1}:
        id: ${PUBLIC_SUBNET_1}
      ${AZ2}:
        id: ${PUBLIC_SUBNET_2}
    private:
      ${AZ1}:
        id: ${PRIVATE_SUBNET_1}
      ${AZ2}:
        id: ${PRIVATE_SUBNET_2}
  clusterEndpoints:
    publicAccess: true
    privateAccess: true

iam:
  withOIDC: true

managedNodeGroups:
  - name: default
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 4
    privateNetworking: true
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
EOF

echo "Config written to /tmp/eksctl-config.yaml"
```

Now create the cluster (~15 minutes):

```bash
eksctl create cluster -f /tmp/eksctl-config.yaml
```

After the cluster is created, verify access:

```bash
kubectl get nodes
kubectl get pods -A
```

**Note:** at this point kubectl is reaching the cluster via a public
endpoint. Step 9 sets up an SSM tunnel as an alternative path, and step 10
disables the public endpoint entirely.

## Step 9: Set up kubectl access via SSM tunnel

This is how you'll access the cluster after disabling the public endpoint.

First, allow the bastion to reach the EKS API server. The cluster security
group only permits traffic from the nodes — the bastion's security group
needs to be added explicitly:

```bash
EKS_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
echo "EKS_SG=$EKS_SG" | tee -a session.sh

aws ec2 authorize-security-group-ingress \
  --group-id "$EKS_SG" \
  --protocol tcp \
  --port 443 \
  --source-group "$BASTION_SG"
```

Next, find the private API endpoint:

```bash
EKS_ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query 'cluster.endpoint' --output text)

# Extract just the hostname from https://XXXXX.gr7.us-east-1.eks.amazonaws.com
EKS_HOST=$(echo "$EKS_ENDPOINT" | sed 's|https://||')

echo "EKS_HOST=$EKS_HOST" | tee -a session.sh
```

Start an SSM port-forwarding session to the EKS API server:

```bash
# Run this in a separate terminal — it stays open as a tunnel
aws ssm start-session \
  --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${EKS_HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"6443\"]}"
```

Update your kubeconfig to use the tunnel:

```bash
# Find the cluster name eksctl wrote to kubeconfig
KUBE_CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
echo "KUBE_CLUSTER=$KUBE_CLUSTER" | tee -a session.sh

# Patch it to point to the local tunnel instead of the public endpoint
kubectl config set-cluster "$KUBE_CLUSTER" --server=https://localhost:6443

# The TLS cert is for the real hostname, not localhost. For development,
# skip TLS verification:
kubectl config set-cluster "$KUBE_CLUSTER" --insecure-skip-tls-verify=true
```

Verify access through the tunnel:

```bash
kubectl get nodes
```

**Alternative: use /etc/hosts instead of insecure-skip-tls-verify.**
If you prefer proper TLS verification, add the EKS hostname to /etc/hosts
pointing at 127.0.0.1, and leave the kubeconfig server as the original
`https://EKS_HOST:6443`.

## Step 10: Install the AWS Load Balancer Controller

This controller watches for Kubernetes Ingress and Service resources and
provisions ALBs/NLBs automatically. Required for exposing Keycloak (public)
and LDAP (internal).

This step must run before disabling the public endpoint (step 11) because
`eksctl` connects directly to the EKS API endpoint — it does not use
kubeconfig, so the SSM tunnel has no effect on it.

```bash
# --- Create IAM policy for the controller ---
curl -o /tmp/alb-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.2/docs/install/iam_policy.json

ALB_POLICY_ARN=$(aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-iam-policy.json \
  --query 'Policy.Arn' --output text)

echo "ALB_POLICY_ARN=$ALB_POLICY_ARN" | tee -a session.sh

# --- Create a service account with IRSA (IAM Roles for Service Accounts) ---
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn "$ALB_POLICY_ARN" \
  --approve

# --- Install the controller via Helm ---
helm repo add eks https://aws.github.io/eks-charts
helm repo update

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID"

# Verify
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## Step 11: Disable the public API endpoint

Once the SSM tunnel is verified (step 9) and all `eksctl`/`helm` setup is
complete (step 10):

```bash
aws eks update-cluster-config \
  --name "$CLUSTER_NAME" \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true
```

This takes a few minutes. Check the status:

```bash
aws eks describe-update \
  --name "$CLUSTER_NAME" \
  --update-id $(aws eks list-updates --name "$CLUSTER_NAME" --query 'updateIds[0]' --output text)
```

From this point on, all kubectl access goes through the SSM tunnel. Note
that `eksctl` commands that need cluster access will no longer work from
outside the VPC.

## Using the cluster for your services

The following examples use `traefik/whoami`, a lightweight container that
responds with request metadata, to demonstrate both public and internal
service exposure.

### Example: deploy whoami

```bash
kubectl create deployment whoami --image=docker.io/traefik/whoami --replicas=2
kubectl expose deployment whoami --port=80 --target-port=80
```

Verify the pods are running:

```bash
kubectl get pods -l app=whoami
```

### Public service (internet-facing ALB)

This creates an internet-facing ALB that anyone can reach. In production,
this is how you'd expose a service like Keycloak.

```yaml
# whoami-public-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami-public
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: whoami
                port:
                  number: 80
```

```bash
kubectl apply -f whoami-public-ingress.yaml

# Wait for the ALB to provision (~2-3 minutes)
kubectl get ingress whoami-public -w
```

Once the ADDRESS column shows a hostname, wait for the ALB to become
active (~2-5 minutes after the hostname appears). DNS won't resolve until
then:

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName,'whoamipu')].State.Code" \
  --output text
```

Once it shows `active`, test it:

```bash
curl http://$(kubectl get ingress whoami-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

### Internal service (VPC-only NLB)

This creates an internal NLB reachable only from within the VPC (or via
VPN/SSM). In production, this is how you'd expose a service like LDAP.

```yaml
# whoami-internal-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: whoami-internal
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  type: LoadBalancer
  selector:
    app: whoami
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f whoami-internal-svc.yaml

# Wait for the NLB to provision (~2-3 minutes)
kubectl get svc whoami-internal -w
```

The EXTERNAL-IP will be an internal hostname that resolves to a private IP
in the VPC. As with the public ALB, wait for the NLB to become active
before testing (~2-5 minutes after the hostname appears):

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName,'whoamiin')].State.Code" \
  --output text
```

Once it shows `active`, test it from the bastion via SSM (the internal
hostname only resolves from within the VPC):

```bash
aws ssm start-session --target "$BASTION_ID"
```

Then from the bastion shell:

```bash
curl http://<internal-nlb-hostname>
```

This endpoint is not reachable from the public internet. Once the
Site-to-Site VPN is configured (see below), it will be reachable from the
corporate network.

### Cleanup

```bash
kubectl delete ingress whoami-public
kubectl delete svc whoami-internal
kubectl delete deployment whoami
```

## Future: Site-to-Site VPN via pfSense

During development, the SSM bastion provides kubectl access without
exposing the cluster publicly. For production use — and to make internal
services (LDAP, etc.) reachable from the corporate network — we'll replace
the SSM tunnel with an AWS Site-to-Site VPN terminated on our pfSense+
firewall.

### Why Site-to-Site VPN

- **pfSense+ includes the "AWS VPC VPN Connection Wizard"** which
  automates the entire setup: it calls the AWS API to create the Virtual
  Private Gateway, Customer Gateway, and VPN Connection, then parses the
  returned configuration XML to auto-configure IPsec tunnels (phase 1/2
  parameters, pre-shared keys, endpoints) on the pfSense side. It also
  updates VPC route tables (enables route propagation) and security groups.
- Once the tunnel is up, the corporate network has direct routed access to
  the VPC private subnets — kubectl works without port-forwarding, and
  internal NLBs are reachable natively.
- Supports both static routing and BGP (via FRR) for route exchange.

### AWS resources involved

| Resource              | Purpose                                  |
|-----------------------|------------------------------------------|
| Virtual Private Gateway (VGW) | AWS-side VPN endpoint, attached to VPC |
| Customer Gateway      | Represents the pfSense public IP         |
| VPN Connection        | Links VGW ↔ Customer Gateway (2 tunnels) |

The wizard creates all three via the AWS API — the only prerequisite is the
VPC itself (which we create in step 1 above).

### What it costs

~$36/month for the VPN Connection (charged whether traffic flows or not),
which replaces the bastion instance (~$8/month) but adds direct network
connectivity for all internal services.

### What to do when ready

1. In the pfSense UI, install the **AWS VPC VPN Connection Wizard** package
   (System > Package Manager).
2. Run the wizard: provide AWS API credentials, select the region and VPC,
   specify local subnets to advertise and VPC subnets to accept.
3. The wizard creates the AWS resources and configures IPsec tunnels.
4. Verify connectivity: from a machine on the corporate network, ping a
   private IP in the VPC (e.g., an EKS node).
5. Update kubeconfig to point directly at the private EKS API endpoint
   (no more localhost tunnel).
6. The SSM bastion can be kept as a fallback or terminated.

## Estimated monthly cost (dev)

| Resource                | Approx. cost  |
|-------------------------|---------------|
| EKS control plane       | $73           |
| 2x t3.medium nodes      | $60           |
| NAT Gateway             | $32 + data    |
| Bastion (t3.micro)      | $8            |
| ALB (if provisioned)    | $16 + data    |
| NLB (if provisioned)    | $16 + data    |
| **Total (baseline)**    | **~$173/mo**  |

## Teardown

To clean everything up (reverse order):

```bash
# Re-enable the public endpoint so eksctl can reach the cluster
aws eks update-cluster-config \
  --name "$CLUSTER_NAME" \
  --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true

# Wait for the update to complete (~5 minutes)
aws eks wait cluster-active --name "$CLUSTER_NAME"

# Delete load balancers created by the controller first
kubectl delete ingress --all -A
kubectl delete svc --all -A  # only LoadBalancer types matter

# Delete the EKS cluster (removes nodes, OIDC provider, etc.)
eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION"

# Delete the bastion
aws ec2 terminate-instances --instance-ids "$BASTION_ID"
aws ec2 wait instance-terminated --instance-ids "$BASTION_ID"

# Delete bastion IAM resources
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${CLUSTER_NAME}-bastion-profile" \
  --role-name "${CLUSTER_NAME}-bastion-role"
aws iam delete-instance-profile --instance-profile-name "${CLUSTER_NAME}-bastion-profile"
aws iam detach-role-policy --role-name "${CLUSTER_NAME}-bastion-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name "${CLUSTER_NAME}-bastion-role"

# Delete ALB controller IAM policy
aws iam delete-policy --policy-arn "$ALB_POLICY_ARN"

# Delete NAT Gateway and Elastic IP
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID"
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GW_ID"  # ~1 min
aws ec2 release-address --allocation-id "$EIP_ALLOC"

# Detach and delete Internet Gateway
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"

# Delete subnets
for S in $PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2 $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2; do
  aws ec2 delete-subnet --subnet-id "$S"
done

# Delete route tables (skip the main/default one)
for RT in $PUBLIC_RT $PRIVATE_RT; do
  # Disassociate first
  for ASSOC in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text); do
    aws ec2 disassociate-route-table --association-id "$ASSOC"
  done
  aws ec2 delete-route-table --route-table-id "$RT"
done

# Delete security groups (non-default)
aws ec2 delete-security-group --group-id "$BASTION_SG"

# Delete VPC
aws ec2 delete-vpc --vpc-id "$VPC_ID"
```
