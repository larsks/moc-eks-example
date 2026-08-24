# MOC EKS example configuration

This repository contains two main assets:

- [`setup-guide.md`](setup-guide.md) is a step-by-step walkthrough of setting up EKS using the AWS command line tools. It includes a worked example of exposing a service on a public ip and of exposing a service on an internal ip. It includes a description of how we would like the VPC to the MOC via a site-to-site VPN.

- The [`tf`](tf/) directory contains an OpenTofu configuration that will deploy the same cluster.

> [!NOTE]
> The API for the EKS cluster created by the OpenTofu configuration is publicly accessible by default. You can set the `public_access_cidrs` to restrict the public availability to specific address ranges.

## Network notes

The file [architecture.svg](architecture.svg) (or [architecture.png](architecture.png)) contains a diagram of the network architecture created by these configurations.

For development access, these configuration set up an [SSM] bastion host. This is almost exactly like an SSH bastion host, except it uses AWS facilities to set up port forwarding from a local machine into the EKS environment. This can be used to establish EKS cluster access [via port forwarding](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html#sessions-start-port-forwarding) without updating `public_access_cidrs`.

[ssm]: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
