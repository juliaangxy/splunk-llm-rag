# Splunk AI Platform on AWS - Project Specification

## Objective

Create a production-grade Infrastructure-as-Code (IaC) project that deploys a complete Splunk AI environment on AWS using CloudFormation.

The deployment must be fully reproducible with minimal manual intervention.

---

# Infrastructure

## Cloud Provider

AWS

## Deployment Method

CloudFormation

Project should be modular with multiple templates.

Suggested structure:

cloudformation/
    network.yaml
    security.yaml
    iam.yaml
    gpu-instance.yaml
    outputs.yaml

---

# Compute

GPU EC2 instance

Default:

g6.4xlarge

Parameterize:

instance type
key pair
subnet
VPC

AMI:

Amazon Linux 2023 NVIDIA Deep Learning AMI

---

# Storage

gp3

Default:

80 GB

Parameterized.

---

# Networking

Create:

Security Group
Elastic IP
IAM Role
Instance Profile

Ingress:

22 (optional)

2375 Docker API

5000 DSDL

11434 Ollama

19530 Milvus

Restrict CIDR using parameters.

---

# Software

Install automatically.

Docker

Docker Compose

NVIDIA Runtime

---

# AI Stack

Deploy automatically.

Ollama

Foundation-Sec-8B

Milvus

MinIO

etcd

Splunk MLTK GPU container

Splunk LLM-RAG container

---

# Splunk Enterprise

Automatically install Splunk Enterprise.

Accept license.

Enable boot-start.

Create admin user.

---

# Splunk Apps

Automatically install:

Python for Scientific Computing

AI Toolkit

DSDL

NVD CVE Add-on

---

# License

User owns an Enterprise License.

License file will be uploaded to AWS separately.

The deployment should retrieve the license from S3.

Parameter:

LicenseBucket

LicenseKey

Bootstrap copies the license into

$SPLUNK_HOME/etc/licenses/enterprise/

Restart Splunk.

---

# Configuration

Enable Docker Remote API.

Configure DSDL Docker endpoint.

Start containers.

Download Foundation-Sec model.

Verify GPU.

Configure container restart policies.

---

# Outputs

Elastic IP

Instance ID

Splunk URL

Ollama URL

Milvus endpoint

SSH command

---

# Bootstrap

Use cloud-init/UserData.

Split into scripts.

01-docker.sh

02-nvidia.sh

03-ollama.sh

04-model.sh

05-milvus.sh

06-splunk.sh

07-license.sh

08-apps.sh

09-configure.sh

10-snapshot.sh

---

# CI/CD

GitHub Actions.

Deploy using AWS CLI.

Validate CloudFormation.

Package templates.

---

# Security

Least privilege IAM.

Parameterize CIDRs.

Do not hardcode secrets.

Do not embed the Splunk license.

Support SSM Session Manager.

---

# Documentation

Generate README.md.

Include:

Architecture

Prerequisites

Deployment

Updating

Troubleshooting

Cleanup